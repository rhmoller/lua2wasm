/* Statement emission: stores and assignment, return, the loops, if, local and
 * global declarations, goto and labels (the dispatch lowering and its
 * pre-pass), and to-be-closed variables. */
#include "internal.h"

/* Fixed-size working-set caps. Each has an explicit overflow guard at its use
 * site that raises a codegen error (never silently truncates). */
#define MAX_BLOCK_LABELS 64  /* ::labels:: declared in one block */
#define MAX_DISPATCH_IDS 128 /* label-bearing blocks per function */

static void emit_close_upto(CG *c, int target, const char *err_wat, int depth);
static void emit_block_stmts(CG *c, const Block *b, int depth);
static void emit_block(CG *c, const Block *b, int depth);

/* Push a loop's break target onto the fixed-size stack. Returns 0 (after
 * setting cg_error) if loop nesting exceeds the stack — callers `break` out
 * of the statement on failure so the depth stays balanced, instead of
 * silently writing past break_labels. */
static int push_break_label(CG *c, int label) {
    int cap = (int)(sizeof(c->break_labels) / sizeof(c->break_labels[0]));
    if (c->break_depth >= cap) {
        cg_error(c, "loop nesting too deep");
        return 0;
    }
    /* Record the live to-be-closed count at loop entry so `break` closes only
     * the <close> locals declared inside this loop. */
    c->break_close_count[c->break_depth] = c->close_count;
    c->break_labels[c->break_depth++] = label;
    return 1;
}

/* ----- goto/label pre-pass -----
 *
 * Walks the function body to:
 *   1. Assign each STMT_LABEL a unique id.
 *   2. Resolve each STMT_GOTO to a target label by lexical lookup
 *      through enclosing blocks; error if unresolved.
 *   3. Copy the target's block_dispatch_id / segment_idx onto the goto so
 *      emit can route it through the right block's br_table.
 *
 * Scope chain mirrors block nesting. For each block we keep an array of
 * the label stmts it declares, no AST pollution.
 */

/* One block's labels: the scope chain mirrors block nesting. */
typedef struct LabelAnalysisScope {
    Stmt *labels[MAX_BLOCK_LABELS]; /* up to MAX_BLOCK_LABELS labels per block */
    int n;
    struct LabelAnalysisScope *parent;
} LabelAnalysisScope;

/* Resolve a goto to its target label by walking the scope chain outward.
 * Returns the matching label stmt, or NULL on miss. */
static Stmt *la_lookup(LabelAnalysisScope *scope, const char *name, size_t len) {
    for (LabelAnalysisScope *s = scope; s; s = s->parent) {
        for (int i = 0; i < s->n; i++) {
            Stmt *lab = s->labels[i];
            if (lab->as.label.name_len == len &&
                memcmp(lab->as.label.name, name, len) == 0) {
                return lab;
            }
        }
    }
    return NULL;
}

static void la_block(CG *c, const Block *b, LabelAnalysisScope *parent);

static void la_recurse_stmt(CG *c, Stmt *s, LabelAnalysisScope *scope) {
    switch (s->kind) {
    case STMT_DO: la_block(c, &s->as.do_stmt.body, scope); break;
    case STMT_WHILE: la_block(c, &s->as.while_stmt.body, scope); break;
    case STMT_REPEAT: la_block(c, &s->as.repeat.body, scope); break;
    case STMT_FOR_NUM: la_block(c, &s->as.for_num.body, scope); break;
    case STMT_FOR_GEN: la_block(c, &s->as.for_gen.body, scope); break;
    case STMT_IF:
        for (size_t i = 0; i < s->as.if_stmt.narms; i++)
            la_block(c, &s->as.if_stmt.arms[i].body, scope);
        if (s->as.if_stmt.has_else)
            la_block(c, &s->as.if_stmt.else_body, scope);
        break;
    /* STMT_LOCAL_FUNC and inline function expressions start a fresh
     * label namespace; emit_user_function runs the pre-pass on those
     * separately when it descends. */
    default: break;
    }
}

static void la_block(CG *c, const Block *b, LabelAnalysisScope *parent) {
    LabelAnalysisScope scope = {.n = 0, .parent = parent};
    /* Pass 1: collect labels, dedup, assign ids. */
    for (size_t i = 0; i < b->count; i++) {
        Stmt *st = b->items[i];
        if (st->kind != STMT_LABEL) continue;
        if (scope.n >= MAX_BLOCK_LABELS) {
            cg_error(c, "too many labels in one block (limit 64)");
            return;
        }
        for (int j = 0; j < scope.n; j++) {
            Stmt *prev = scope.labels[j];
            if (prev->as.label.name_len == st->as.label.name_len &&
                memcmp(prev->as.label.name, st->as.label.name,
                       st->as.label.name_len) == 0) {
                char msg[128];
                int n = (int)(st->as.label.name_len < 80 ? st->as.label.name_len : 80);
                snprintf(msg, sizeof(msg),
                         "label '%.*s' already defined in this block",
                         n, st->as.label.name);
                cg_error(c, msg);
                return;
            }
        }
        st->as.label.id = c->next_label_id++;
        st->as.label.segment_idx = scope.n + 1; /* 1-based; segment 0 is "before any label" */
        scope.labels[scope.n] = st;
        scope.n++;
    }
    /* All labels in this block share the same dispatch-block id: by
     * convention the id of the first label declared in the block. */
    int block_dispatch_id = scope.n > 0 ? scope.labels[0]->as.label.id : -1;
    for (int i = 0; i < scope.n; i++) {
        scope.labels[i]->as.label.block_dispatch_id = block_dispatch_id;
    }
    /* Pass 2: resolve gotos in this block, recurse into nested blocks. */
    for (size_t i = 0; i < b->count; i++) {
        Stmt *st = b->items[i];
        if (st->kind == STMT_GOTO) {
            Stmt *lab = la_lookup(&scope, st->as.label.name, st->as.label.name_len);
            if (!lab) {
                char msg[128];
                int n = (int)(st->as.label.name_len < 80 ? st->as.label.name_len : 80);
                snprintf(msg, sizeof(msg),
                         "no visible label '%.*s' for goto", n, st->as.label.name);
                cg_error(c, msg);
                return;
            }
            st->as.label.block_dispatch_id = lab->as.label.block_dispatch_id;
            st->as.label.target_segment_idx = lab->as.label.segment_idx;
            /* The goto closes to-be-closed vars down to the target's depth
             * (stamped by la_close_bases, which runs before this pass). */
            st->as.label.close_base = lab->as.label.close_base;
        } else if (st->kind != STMT_LABEL) {
            la_recurse_stmt(c, st, &scope);
        }
    }
}

static int for_gen_has_closing(const Stmt *s);

/* Stamp every STMT_LABEL with the count of to-be-closed variables in scope at
 * that label (`running`), walking statements in source order. Runs before
 * la_block, which copies each label's base onto the gotos that target it.
 * Does not descend into nested function bodies (they get their own pass). */
static void la_close_bases(const Block *b, int running) {
    for (size_t i = 0; i < b->count; i++) {
        Stmt *s = b->items[i];
        switch (s->kind) {
        case STMT_LABEL:
            s->as.label.close_base = running;
            break;
        case STMT_LOCAL:
            if (s->as.local.attribs)
                for (int j = 0; j < s->as.local.n_names; j++)
                    if (s->as.local.attribs[j] == 2) running++;
            break;
        case STMT_DO: la_close_bases(&s->as.do_stmt.body, running); break;
        case STMT_WHILE: la_close_bases(&s->as.while_stmt.body, running); break;
        case STMT_REPEAT: la_close_bases(&s->as.repeat.body, running); break;
        case STMT_FOR_NUM: la_close_bases(&s->as.for_num.body, running); break;
        case STMT_FOR_GEN:
            /* The generic-for closing value is in scope for the loop body. */
            la_close_bases(&s->as.for_gen.body, running + for_gen_has_closing(s));
            break;
        case STMT_IF:
            for (size_t a = 0; a < s->as.if_stmt.narms; a++)
                la_close_bases(&s->as.if_stmt.arms[a].body, running);
            if (s->as.if_stmt.has_else)
                la_close_bases(&s->as.if_stmt.else_body, running);
            break;
        default: break;
        }
    }
}

/* ----- statement arms (split out of emit_stmt) ----- */

/* Whether a stored value is worth lowering into a cell, so that a float
 * result can go to a table's unboxed float storage: a provable float, an
 * arithmetic tree over an opaque operand, a maybe slot, or an inline math
 * call. A bare table read or ordinary call is a boxed value already — passing
 * it through the plain store is cheaper than classifying and re-boxing it. */
static int store_value_lowers(CG *c, const Expr *v) {
    if (expr_is_float(c, v)) return 1;
    switch (v->kind) {
    case EXPR_BINOP:
    case EXPR_UNOP: return expr_involves_maybe(c, v);
    case EXPR_VAR: return v->as.var.kind == VAR_LOCAL && slot_is_maybe(c, v->as.var.idx);
    case EXPR_CALL:
        return v->as.call.nargs == 1 && !is_multival_tail(v->as.call.args[0]) &&
               callee_math_kind(c, v->as.call.callee) != MB_NONE;
    default: return 0;
    }
}

/* Lower a store's value into cell `vc`: a provable float straight into the f64
 * part, anything else through the maybe lowering. */
static void emit_store_value_cell(CG *c, const Expr *v, const MCell *vc, int depth) {
    if (expr_is_float(c, v)) {
        emit_linef(c, depth, "(local.set %s\n", vc->sf);
        emit_float_expr(c, v, depth + 1);
        emit_line(c, depth, ")\n");
        emit_set_tag(c, vc, TAG_FLOAT, depth);
    } else {
        emit_maybe_lower(c, v, vc, depth);
    }
}

/* How an index store's key is held: a constant string (the hoisted global
 * `kb`), an i64 (kc.i), a maybe cell (kc), or a boxed value (kc.b). */
typedef enum { SK_STR,
               SK_INT,
               SK_MAYBE,
               SK_ANY } StoreKey;

/* The store `tb[key] = value` with the table, key and value already
 * evaluated. A lowered value (vc a cell) that is a float goes to the unboxed
 * `_f` setter when the key allows it, else the value is boxed; a plain value
 * (`vb`, a boxed expression) takes the boxed setter. Every setter still
 * dispatches __newindex. */
static void emit_index_store_from(CG *c, const char *tb, StoreKey kkind, const char *kb, const MCell *kc,
                                  const MCell *vc, const char *vb, int append, int depth) {
    char box[256], icb[48], store[640];
    if (vc) snprintf(box, sizeof box, "(call $box_num %s %s %s %s)", vc->t, vc->i, vc->f, vc->b);
    else snprintf(box, sizeof box, "%s", vb);
    if (kkind == SK_INT || kkind == SK_MAYBE) { /* the array part written inline (arrays.c) */
        IxKey k = kkind == SK_INT ? (IxKey){.i = kc->i, .append = append} : (IxKey){.cell = kc, .append = append};
        int d = depth;
        if (vc) {
            if (kkind == SK_MAYBE)
                emit_linef(c, depth, "(if (i32.and (i32.eq %s (i32.const 2)) (i32.eq %s (i32.const 1)))\n", vc->t,
                           kc->t);
            else emit_linef(c, depth, "(if (i32.eq %s (i32.const 2))\n", vc->t);
            emit_line(c, depth + 1, "(then\n");
            emit_ix_set_f(c, tb, kc->i, vc->f, depth + 2);
            emit_line(c, depth + 1, ")\n");
            emit_line(c, depth + 1, "(else\n");
            d = depth + 2;
        }
        if (vc) emit_linef(c, d, "(local.set $ix_v %s)\n", box);
        emit_ix_set(c, tb, k, vc ? "(local.get $ix_v)" : vb, d);
        if (vc) emit_line(c, depth + 1, "))\n");
        return;
    }
    /* a constant-key store goes through one inline cache for both forms */
    const char *ic = kkind == SK_STR ? ic_new(c, icb, sizeof icb) : NULL;
    switch (kkind) {
    case SK_STR:
        if (ic) snprintf(store, sizeof store, "(call $lua_tabset_ic %s %s %s %s)", ic, tb, kb, box);
        else snprintf(store, sizeof store, "(call $lua_tabset_sk %s %s %s)", tb, kb, box);
        break;
    default: snprintf(store, sizeof store, "(call $lua_tabset %s %s %s)", tb, kc->b, box); break;
    }
    if (!vc || kkind == SK_ANY) {
        emit_linef(c, depth, "%s\n", store);
        return;
    }
    emit_linef(c, depth, "(if (i32.eq %s (i32.const 2))\n", vc->t);
    if (ic) emit_linef(c, depth + 1, "(then (call $lua_tabset_ic_f %s %s %s %s))\n", ic, tb, kb, vc->f);
    else emit_linef(c, depth + 1, "(then (call $lua_tabset_sk_f %s %s %s))\n", tb, kb, vc->f);
    emit_linef(c, depth + 1, "(else %s))\n", store);
}

/* `slot = e` for a local the analyses typed (int, float or maybe); returns 0,
 * emitting nothing, for an untyped slot. */
static int emit_typed_slot_store(CG *c, int slot, const Expr *e, int depth) {
    if (slot_is_int(c, slot)) {
        /* i64 slot: the analysis guarantees a matching single int value. */
        emit_linef(c, depth, "(local.set $L%d\n", slot);
        emit_int_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
    } else if (slot_is_float(c, slot)) {
        emit_linef(c, depth, "(local.set $L%d\n", slot);
        emit_float_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
    } else if (slot_is_maybe(c, slot)) {
        emit_maybe_store(c, slot, e, depth);
    } else {
        return 0;
    }
    return 1;
}

/* `x = e` for a variable held in an $IBox (the analysis proved `e` int-typed);
 * returns 0, emitting nothing, for any other variable. */
static int emit_ibox_store(CG *c, VarRef v, const Expr *e, int depth) {
    if (!(v.kind == VAR_LOCAL ? slot_is_ibox(c, v.idx) : v.kind == VAR_UPVAL && upval_is_ibox(c, v.idx))) return 0;
    emit_line(c, depth, "(struct.set $IBox $i ");
    emit_ibox_ref(c, v.kind, v.idx);
    wat_append(c->w, "\n");
    emit_int_expr(c, e, depth + 1);
    emit_line(c, depth, ")\n");
    return 1;
}

/* The declaration-time store of a local: a captured slot gets a fresh $Box
 * around the value (each declaration is a new variable), any other slot the
 * value itself. The value is emitted between open and close. */
static void emit_local_init_open(CG *c, int slot, int depth) {
    emit_linef(c, depth, slot_is_boxed(c, slot) ? "(local.set $L%d (struct.new $Box\n" : "(local.set $L%d\n", slot);
}
static void emit_local_init_close(CG *c, int slot, int depth) {
    emit_line(c, depth, slot_is_boxed(c, slot) ? "))\n" : ")\n");
}

/* A key spelled `#x + 1` (or `1 + #x`): the store is most likely an append. */
static int key_is_append(const Expr *k) {
    if (k->kind != EXPR_BINOP || k->as.binop.op != BIN_ADD) return 0;
    const Expr *l = k->as.binop.lhs, *r = k->as.binop.rhs;
    int llen = l->kind == EXPR_UNOP && l->as.unop.op == UN_LEN, rlen = r->kind == EXPR_UNOP && r->as.unop.op == UN_LEN;
    int lone = l->kind == EXPR_INT && l->as.i_val == 1, rone = r->kind == EXPR_INT && r->as.i_val == 1;
    return (llen && rone) || (lone && rlen);
}

/* `t[k] = v` where v is a lowered tree or a provably float expression and k
 * is a constant string, an int-typed expression or a maybe slot — or where k
 * is itself a lowered arithmetic tree (`t[#t + 1] = v`): evaluate the table
 * (Lua order: table, key, value), the key into a cell when lowered, the
 * value into a cell when it lowers, and store an f64 straight into the
 * table's unboxed float storage when the result is a float — no $LuaFloat
 * allocation — else the boxed store; an int key, or a lowered one that came
 * out an int, takes the inline array-part path. Returns 0 (nothing emitted)
 * when the shape doesn't qualify. */
static int emit_unboxed_index_store(CG *c, const AssignTarget *t, const Expr *v, int depth) {
    if (!c->opt_int || !c->cur_is_maybe) return 0;
    const Expr *key = t->as.index.key;
    int kstr = key->kind == EXPR_STRING && key->as.s.len <= KSTR_MAX;
    int kint = !kstr && expr_is_int(c, key);
    int kmaybe = !kstr && !kint && key->kind == EXPR_VAR && key->as.var.kind == VAR_LOCAL &&
                 slot_is_maybe(c, key->as.var.idx);
    int klow = !kstr && !kint && !kmaybe && key->kind == EXPR_BINOP && maybe_arith_op(key->as.binop.op) &&
               expr_involves_maybe(c, key);
    int lowers = store_value_lowers(c, v);
    if (!(kstr || kint || kmaybe || klow)) return 0;
    if (!lowers && !klow) return 0;
    int k = mt_alloc(c, 3);
    MCell tc = mcell_tmp(k), kl = mcell_tmp(k + 1), vc = mcell_tmp(k + 2);
    emit_linef(c, depth, "(local.set %s\n", tc.sb);
    emit_expr(c, t->as.index.table, depth + 1);
    emit_line(c, depth, ")\n");
    if (kint) { /* the key is evaluated once, before the value */
        emit_linef(c, depth, "(local.set %s\n", tc.si);
        emit_int_expr(c, key, depth + 1);
        emit_line(c, depth, ")\n");
    } else if (klow) {
        emit_maybe_lower(c, key, &kl, depth);
    }
    if (lowers) {
        emit_store_value_cell(c, v, &vc, depth);
    } else {
        emit_linef(c, depth, "(local.set %s\n", vc.sb);
        emit_expr(c, v, depth + 1);
        emit_line(c, depth, ")\n");
    }
    char kb[160] = "";
    if (kstr) kstr_expr(c, key->as.s.bytes, key->as.s.len, kb, sizeof kb);
    MCell kc = kmaybe ? mcell_slot(key->as.var.idx) : klow ? kl
                                                           : tc;
    emit_index_store_from(c, tc.b, kstr ? SK_STR : kint ? SK_INT
                                                        : SK_MAYBE,
                          kb, &kc, lowers ? &vc : NULL, vc.b, klow && key_is_append(key), depth);
    c->mt_depth = k;
    return 1;
}

/* Multi-assignment `t1[k1], x, t2[k2] = v1, v2, v3` with one value per target,
 * through lowering temporaries instead of the $ArgArr path: every target's
 * table and key is evaluated (left to right) into a cell, then every value —
 * lowered when it can yield an unboxed float — and finally the stores run
 * right to left (so a repeated target keeps its leftmost value, as in
 * reference Lua). Keys are snapshotted, so `t[i], i = 1, 2` indexes with the
 * old i. Index stores take the same constant-string / int / maybe-key and
 * unboxed-float setters as a single store. Returns 0 when not applicable. */
static int emit_assign_multi_cells(CG *c, const Stmt *s, int depth) {
    int nt = s->as.assign.n_targets;
    if (!c->opt_int || nt < 2 || s->as.assign.n_values != nt) return 0;
    for (int i = 0; i < nt; i++) {
        const AssignTarget *t = &s->as.assign.targets[i];
        if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL && slot_is_maybe(c, t->as.var.idx)) return 0;
    }
    int k0 = c->mt_depth;
    /* per target: table, key and value cells, key kind, value lowered?, key string */
    struct {
        MCell t, k, v;
        StoreKey kkind;
        int lowered;
        char kb[160];
    } *g = xmalloc((size_t)nt * sizeof *g);
    for (int i = 0; i < nt; i++) {
        const AssignTarget *t = &s->as.assign.targets[i];
        g[i].kb[0] = '\0';
        if (t->kind == TGT_VAR) continue;
        const Expr *key = t->as.index.key;
        g[i].t = mcell_tmp(mt_alloc(c, 1));
        emit_linef(c, depth, "(local.set %s\n", g[i].t.sb);
        emit_expr(c, t->as.index.table, depth + 1);
        emit_line(c, depth, ")\n");
        if (key->kind == EXPR_STRING && key->as.s.len <= KSTR_MAX) {
            g[i].kkind = SK_STR;
            kstr_expr(c, key->as.s.bytes, key->as.s.len, g[i].kb, sizeof g[i].kb);
            continue;
        }
        g[i].k = mcell_tmp(mt_alloc(c, 1));
        if (expr_is_int(c, key)) {
            g[i].kkind = SK_INT;
            emit_linef(c, depth, "(local.set %s\n", g[i].k.si);
            emit_int_expr(c, key, depth + 1);
            emit_line(c, depth, ")\n");
        } else if (key->kind == EXPR_VAR && key->as.var.kind == VAR_LOCAL && slot_is_maybe(c, key->as.var.idx)) {
            g[i].kkind = SK_MAYBE;
            MCell ks = mcell_slot(key->as.var.idx);
            emit_linef(c, depth, "(local.set %s %s) (local.set %s %s) (local.set %s %s) (local.set %s %s)\n",
                       g[i].k.st, ks.t, g[i].k.si, ks.i, g[i].k.sf, ks.f, g[i].k.sb, ks.b);
        } else {
            g[i].kkind = SK_ANY;
            emit_linef(c, depth, "(local.set %s\n", g[i].k.sb);
            emit_expr(c, key, depth + 1);
            emit_line(c, depth, ")\n");
        }
    }
    for (int i = 0; i < nt; i++) {
        const Expr *v = s->as.assign.values[i];
        g[i].v = mcell_tmp(mt_alloc(c, 1));
        g[i].lowered = s->as.assign.targets[i].kind == TGT_INDEX && store_value_lowers(c, v);
        if (g[i].lowered) {
            emit_store_value_cell(c, v, &g[i].v, depth);
        } else {
            emit_linef(c, depth, "(local.set %s\n", g[i].v.sb);
            emit_expr(c, v, depth + 1);
            emit_line(c, depth, ")\n");
        }
    }
    for (int i = nt - 1; i >= 0; i--) {
        const AssignTarget *t = &s->as.assign.targets[i];
        if (t->kind == TGT_VAR) {
            emit_target_open(c, t, depth);
            emit_linef(c, depth + 1, "%s\n", g[i].v.b);
            emit_target_close(c, t, depth);
        } else {
            emit_index_store_from(c, g[i].t.b, g[i].kkind, g[i].kb, &g[i].k, g[i].lowered ? &g[i].v : NULL,
                                  g[i].v.b, 0, depth);
        }
    }
    free(g);
    c->mt_depth = k0;
    return 1;
}

static void emit_assign(CG *c, const Stmt *s, int depth) {
    int n_targets = s->as.assign.n_targets;
    int n_values = s->as.assign.n_values;
    /* Fast path only for exactly one target and one value. With a longer
     * value list (`a = 5, g()`) the extra values must still be evaluated
     * left-to-right for their side effects; fall through to the general
     * path, which builds the full value array and stores target[0] from
     * it. */
    if (n_targets == 1 && n_values == 1) {
        AssignTarget *t = &s->as.assign.targets[0];
        if (t->kind == TGT_VAR && emit_ibox_store(c, t->as.var, s->as.assign.values[0], depth)) return;
        if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL &&
            emit_typed_slot_store(c, t->as.var.idx, s->as.assign.values[0], depth))
            return;
        if (t->kind == TGT_INDEX && emit_unboxed_index_store(c, t, s->as.assign.values[0], depth)) return;
        /* A lone call / `...` value supplies its first value (emit_expr takes
         * the call's single-value entry). */
        emit_target_open(c, t, depth);
        emit_expr(c, s->as.assign.values[0], depth + 1);
        emit_target_close(c, t, depth);
        return;
    }
    if (emit_assign_multi_cells(c, s, depth)) return;
    /* Multi-target. Lua evaluates every LHS table/key sub-expression
     * and every RHS value *before* any store, then stores right-to-
     * left (so a repeated target keeps its leftmost value, matching
     * reference). Concretely: `i, t[i] = i+1, 99` must capture t[i]'s
     * index before i is reassigned, and `g.a, g.b, g.a = 1, 2, 3`
     * must leave g.a == 1.
     *
     * Pre-evaluate index targets' table+key into parallel arrays
     * (left-to-right); plain var targets have a static address and
     * need no pre-eval, so we skip the arrays entirely when every
     * target is a variable. (last_call is only relevant to the
     * single-target branch above; the multi-target path always
     * builds the full $tmp_args array via emit_args_array.) */
    /* An index target whose table and key are non-captured locals (or the
     * key a literal) has a static address too: evaluating the values first
     * can't change it, and neither can an earlier store's __newindex (locals
     * are unreachable from metamethods unless captured). Such targets store
     * through emit_target_open like single stores — keeping the int / maybe /
     * constant-key fast paths (`q[i], q[j] = q[j], q[i]`). */
    int has_index = 0;
    for (int i = 0; i < n_targets; i++) {
        AssignTarget *t = &s->as.assign.targets[i];
        if (t->kind == TGT_VAR) continue;
        const Expr *tb = t->as.index.table, *k = t->as.index.key;
        int tb_static = tb->kind == EXPR_VAR && tb->as.var.kind == VAR_LOCAL && !slot_is_boxed(c, tb->as.var.idx);
        int k_static = k->kind == EXPR_INT || k->kind == EXPR_FLOAT || k->kind == EXPR_STRING ||
                       (k->kind == EXPR_VAR && k->as.var.kind == VAR_LOCAL && !slot_is_boxed(c, k->as.var.idx));
        if (!(tb_static && k_static)) {
            has_index = 1;
            break;
        }
    }
    if (has_index) {
        emit_linef(c, depth, "(local.set $tmp_lhs_t (array.new $ArgArr (ref.null any) "
                             "(i32.const %d)))\n",
                   n_targets);
        emit_linef(c, depth, "(local.set $tmp_lhs_k (array.new $ArgArr (ref.null any) "
                             "(i32.const %d)))\n",
                   n_targets);
        for (int i = 0; i < n_targets; i++) {
            AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind == TGT_VAR) continue;
            emit_linef(c, depth, "(array.set $ArgArr (ref.as_non_null (local.get $tmp_lhs_t)) "
                                 "(i32.const %d)\n",
                       i);
            emit_expr(c, t->as.index.table, depth + 1);
            emit_line(c, depth, ")\n");
            emit_linef(c, depth, "(array.set $ArgArr (ref.as_non_null (local.get $tmp_lhs_k)) "
                                 "(i32.const %d)\n",
                       i);
            emit_expr(c, t->as.index.key, depth + 1);
            emit_line(c, depth, ")\n");
        }
    }
    emit_line(c, depth, "(local.set $tmp_args\n");
    emit_args_array(c, s->as.assign.values, n_values, depth + 1);
    emit_line(c, depth, ")\n");
    for (int i = n_targets - 1; i >= 0; i--) {
        AssignTarget *t = &s->as.assign.targets[i];
        if (t->kind == TGT_VAR || !has_index) {
            emit_target_open(c, t, depth);
            emit_args_at(c, i, depth + 1);
            emit_target_close(c, t, depth);
        } else {
            /* index target: store via pre-evaluated table+key so
             * __newindex still fires (matches emit_target_open). */
            emit_line(c, depth, "(call $lua_tabset\n");
            emit_linef(c, depth + 1, "(array.get $ArgArr (ref.as_non_null (local.get $tmp_lhs_t)) "
                                     "(i32.const %d))\n",
                       i);
            emit_linef(c, depth + 1, "(array.get $ArgArr (ref.as_non_null (local.get $tmp_lhs_k)) "
                                     "(i32.const %d))\n",
                       i);
            emit_args_at(c, i, depth + 1);
            emit_line(c, depth, ")\n");
        }
    }
}

/* Does the body being emitted return exactly one value ($user_N_da1 or
 * $user_N_f) rather than a result array? */
static int entry_single_result(const CG *c) { return c->entry == ENTRY_DIRECT1 || c->entry == ENTRY_FAST; }

/* Evaluate values[from..n) for their side effects only. */
static void emit_values_dropped(CG *c, Expr **values, int from, int n, int depth) {
    for (int i = from; i < n; i++) {
        emit_expr(c, values[i], depth);
        emit_line(c, depth, "drop\n");
    }
}

/* The returned values in the shape the entry returns, left on the stack: one
 * value (raw i64/f64 for a numerically typed single-result entry; extra
 * values still evaluate, in order) or the result array. */
static void emit_return_values(CG *c, Expr **values, int n, int depth) {
    if (entry_single_result(c)) {
        if ((c->cur_ret_ty == NT_INT || c->cur_ret_ty == NT_FLOAT) && n == 1) {
            if (c->cur_ret_ty == NT_INT)
                emit_int_expr(c, values[0], depth);
            else
                emit_num_as_f64(c, values[0], depth);
        } else if (n == 0) {
            emit_line(c, depth, "(ref.null any)\n");
        } else {
            emit_expr(c, values[0], depth);
            emit_values_dropped(c, values, 1, n, depth);
        }
    } else if (n == 1 && is_multival_tail(values[0])) {
        /* A lone multi-value tail (a single call/vararg) returns its array as-is. */
        emit_multival_array(c, values[0], depth);
    } else {
        emit_args_array(c, values, n, depth);
    }
}

static void emit_return(CG *c, const Stmt *s, int depth) {
    Expr **values = s->as.return_stmt.values;
    int n_values = s->as.return_stmt.n_values;
    if (c->ol_active) {
        /* Inside an outlined loop's function: close what is open, park the
         * result in $ol_ret and leave with status RETURN; the caller returns
         * it (outline.c). Never a tail call — the callee runs before the
         * enclosing function returns, as it would after a close. */
        if (c->in_main) emit_values_dropped(c, values, 0, n_values, depth);
        else emit_return_values(c, values, n_values, depth);
        if (c->close_count > 0) emit_close_upto(c, 0, "(ref.null any)", depth);
        if (!c->in_main) emit_line(c, depth, "(local.set $ol_ret)\n");
        emit_linef(c, depth, "(local.set $ol_status (i32.const %d))\n", OL_RETURN);
        emit_line(c, depth, "(br $ol_exit)\n");
        return;
    }
    if (c->in_main) {
        /* $main is exported with no result, so the chunk's return
         * value can't be surfaced to the host — but we still have
         * to evaluate the expressions so their side effects fire
         * (e.g. `return print("hi")`). Drop each result after
         * evaluation, close what is open, then exit. */
        emit_values_dropped(c, values, 0, n_values, depth);
        if (c->close_count > 0) emit_close_upto(c, 0, "(ref.null any)", depth);
        emit_line(c, depth, "return\n");
        return;
    }
    if (c->close_count > 0) {
        /* Close-aware return: any to-be-closed local in scope must be closed
         * before the function returns. Evaluate the result onto the stack
         * first ($close_upto is stack-neutral, so it stays beneath), then
         * close the whole to-be-closed stack (down to 0), then return. A
         * `return f()` here is NOT a tail call — the locals must close after
         * f() returns. */
        emit_return_values(c, values, n_values, depth);
        emit_close_upto(c, 0, "(ref.null any)", depth);
        emit_line(c, depth, "return\n");
        return;
    }
    if (c->entry == ENTRY_FAST && n_values == 1 && !values[0]->paren && fast_call_nargs(c, values[0]) >= 0) {
        /* A $user_N_f body's tail call that fits the fast entry stays a
         * proper tail call; wider ones fall to the single-value code below
         * (an ordinary call — the callee's generic body keeps its own tail
         * calls proper, so the stack stays bounded). */
        emit_fast_tail_call(c, values[0], depth);
        return;
    }
    if (entry_single_result(c)) {
        /* Single-value-return entry ($user_N_da1): produce exactly one
         * value of the entry's result type. A numeric ret_ty was inferred
         * only when every return is a single numeric value, so emit it
         * raw (i64/f64). */
        if ((c->cur_ret_ty == NT_INT || c->cur_ret_ty == NT_FLOAT) && n_values == 1) {
            emit_line(c, depth, "(return\n");
            if (c->cur_ret_ty == NT_INT) emit_int_expr(c, values[0], depth + 1);
            else emit_num_as_f64(c, values[0], depth + 1);
            emit_line(c, depth, ")\n");
            return;
        }
        /* ret_ty == ANY: produce a single anyref. A non-vararg body never
         * uses `...`, so a lone multi-value tail here is a call, adjusted
         * to one by emit_expr. Extra return values still evaluate (side
         * effects), in order. */
        if (n_values == 0) {
            emit_line(c, depth, "(return (ref.null any))\n");
        } else if (n_values == 1) {
            emit_line(c, depth, "(return\n");
            emit_expr(c, values[0], depth + 1);
            emit_line(c, depth, ")\n");
        } else {
            emit_line(c, depth, "(local.set $tmp_any\n");
            emit_expr(c, values[0], depth + 1);
            emit_line(c, depth, ")\n");
            emit_values_dropped(c, values, 1, n_values, depth);
            emit_line(c, depth, "(return (local.get $tmp_any))\n");
        }
        return;
    }
    /* Tail-call optimization: exactly `return f(args)` or
     * `return obj:m(args)` (not parenthesized, which forces adjust-to-
     * one and so isn't a tail call). */
    if (n_values == 1 && !values[0]->paren && (values[0]->kind == EXPR_CALL || values[0]->kind == EXPR_METHOD_CALL)) {
        emit_tail_call(c, values[0], depth);
        return;
    }
    /* `return f(), x, ...` and similar: build the result array. */
    emit_return_values(c, values, n_values, depth);
    emit_line(c, depth, "return\n");
}

/* `(br_if $brk_<label> (i64.<op> a b))`, leaving an integer for loop: `op` is
 * `asc` when the loop counts up and `desc` when it counts down; when the
 * step's sign is unknown at compile time (sign == 0) it is tested at run time. */
static void emit_int_for_exit(CG *c, int label, int sign, const char *step, const char *asc, const char *desc,
                              const char *a, const char *b, int depth) {
    if (sign)
        emit_linef(c, depth, "(br_if $brk_%d (i64.%s %s %s))\n", label, sign > 0 ? asc : desc, a, b);
    else
        emit_linef(c, depth,
                   "(if (i64.gt_s %s (i64.const 0)) (then (br_if $brk_%d (i64.%s %s %s))) "
                   "(else (br_if $brk_%d (i64.%s %s %s))))\n",
                   step, label, asc, a, b, label, desc, a, b);
}

/* The integer-specialized loop: control var + bounds are i64, the
 * counter is an unboxed i64 slot, no per-iteration boxing or
 * generic-helper calls. The analysis only marks the slot int when
 * start and step are integer and the var isn't captured; a limit that
 * isn't statically an integer is converted once by $for_limit. */
static void emit_for_num_int(CG *c, const Stmt *s, int label, int depth) {
    int slot = s->as.for_num.local_idx;
    int fd = c->for_depth;
    const Expr *st = s->as.for_num.step;
    int stop_int = expr_is_int(c, s->as.for_num.stop);
    char step_s[40];
    int sign; /* +1/-1 known at compile time; 0 = runtime */
    if (!st) {
        snprintf(step_s, sizeof step_s, "(i64.const 1)");
        sign = 1;
    } else if (st->kind == EXPR_INT && st->as.i_val != 0) {
        snprintf(step_s, sizeof step_s, "(i64.const %lld)", (long long)st->as.i_val);
        sign = st->as.i_val > 0 ? 1 : -1;
    } else {
        snprintf(step_s, sizeof step_s, "(local.get $ifor_step_%d)", fd);
        sign = 0;
    }
    char var[32], stop[40], next[40];
    snprintf(var, sizeof var, "(local.get $L%d)", slot);
    snprintf(stop, sizeof stop, "(local.get $ifor_stop_%d)", fd);
    snprintf(next, sizeof next, "(local.get $ifor_next_%d)", fd);
    ol_init_open(c, s, depth);
    emit_linef(c, depth, "(local.set $L%d\n", slot);
    emit_int_expr(c, s->as.for_num.start, depth + 1);
    emit_line(c, depth, ")\n");
    emit_indent(c, depth);
    if (stop_int) {
        wat_appendf(c->w, "(local.set $ifor_stop_%d\n", fd);
        emit_int_expr(c, s->as.for_num.stop, depth + 1);
    } else {
        wat_appendf(c->w, "(local.set $for_stop_%d\n", fd);
        emit_expr(c, s->as.for_num.stop, depth + 1);
    }
    emit_line(c, depth, ")\n");
    if (sign == 0) {
        emit_linef(c, depth, "(local.set $ifor_step_%d\n", fd);
        emit_int_expr(c, st, depth + 1);
        emit_line(c, depth, ")\n");
        emit_linef(c, depth, "(if (i64.eqz %s) (then (call $throw_lit_at %s (i32.const %d))))\n",
                   step_s, slab_ref("'for' step is zero"), s->line);
    }
    if (!stop_int) {
        emit_linef(c, depth, "(call $for_limit (local.get $for_stop_%d) (local.get $L%d) %s (i32.const %d))\n", fd,
                   slot, step_s, s->line);
        emit_linef(c, depth, "(local.set $for_skip_%d)\n", fd);
        emit_linef(c, depth, "(local.set $ifor_stop_%d)\n", fd);
    }
    ol_init_close(c, s, depth);
    emit_linef(c, depth, "(block $brk_%d\n", label);
    if (!stop_int) {
        emit_linef(c, depth + 1, "(br_if $brk_%d (local.get $for_skip_%d))\n", label, fd);
    }
    emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
    ol_loop_header(c, s, depth + 2);
    /* Exit when the counter has passed the limit. */
    emit_int_for_exit(c, label, sign, step_s, "gt_s", "lt_s", var, stop, depth + 2);
    c->for_depth++;
    emit_block(c, &s->as.for_num.body, depth + 2);
    c->for_depth--;
    emit_linef(c, depth + 2, "(local.set $ifor_next_%d (i64.add (local.get $L%d) %s))\n", fd, slot, step_s);
    /* Exit when the step wrapped past the integer range. */
    emit_int_for_exit(c, label, sign, step_s, "lt_s", "gt_s", next, var, depth + 2);
    emit_linef(c, depth + 2, "(local.set $L%d (local.get $ifor_next_%d))\n", slot, fd);
    emit_linef(c, depth + 2, "br $cont_%d\n", label);
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
}

/* The generic loop over boxed control values: $for_prep settles the loop's
 * type at entry, the step goes through $lua_add with an overflow check. */
static void emit_for_num_boxed(CG *c, const Stmt *s, int label, int depth) {
    int slot = s->as.for_num.local_idx;
    int boxed = slot_is_boxed(c, slot);
    /* Per-nesting-level scratch so an inner for-loop can't clobber
     * this loop's stop/step. */
    int fd = c->for_depth;
    char f_stop[24], f_step[24], f_next[24], f_cur[24];
    snprintf(f_stop, sizeof f_stop, "$for_stop_%d", fd);
    snprintf(f_step, sizeof f_step, "$for_step_%d", fd);
    snprintf(f_next, sizeof f_next, "$for_next_%d", fd);
    snprintf(f_cur, sizeof f_cur, "$for_cur_%d", fd);
    /* The running counter lives in a scratch local; stash stop/step
     * alongside. When the control variable is captured (boxed), the
     * counter must stay separate from the user-visible $Box so that
     * each iteration can bind a FRESH box (Lua 5.4+: the loop
     * variable is a new local per iteration, so closures capture
     * distinct values). When it isn't captured the slot holds the
     * value directly and doubles as the counter. */
    ol_init_open(c, s, depth);
    emit_indent(c, depth);
    if (boxed) {
        wat_appendf(c->w, "(local.set %s\n", f_cur);
    } else {
        wat_appendf(c->w, "(local.set $L%d\n", slot);
    }
    emit_expr(c, s->as.for_num.start, depth + 1);
    emit_line(c, depth, ")\n");
    emit_linef(c, depth, "(local.set %s\n", f_stop);
    emit_expr(c, s->as.for_num.stop, depth + 1);
    emit_line(c, depth, ")\n");
    emit_linef(c, depth, "(local.set %s\n", f_step);
    if (s->as.for_num.step) {
        emit_expr(c, s->as.for_num.step, depth + 1);
    } else {
        emit_line(c, depth + 1, "(ref.i31 (i32.const 1))\n");
    }
    emit_line(c, depth, ")\n");
    /* $for_prep applies Lua's forprep: it settles the loop's type (integer
     * iff init and step are integers, else all three coerced to floats),
     * converts the limit, raises on a zero step or a non-numeric value, and
     * says whether the loop runs at all. counter_loc is the local that holds
     * the running value. */
    char counter_loc[24];
    if (boxed) snprintf(counter_loc, sizeof counter_loc, "%s", f_cur);
    else snprintf(counter_loc, sizeof counter_loc, "$L%d", slot);
    char f_skip[24];
    snprintf(f_skip, sizeof f_skip, "$for_skip_%d", fd);
    emit_linef(c, depth, "(call $for_prep (local.get %s) (local.get %s) (local.get %s) (i32.const %d))\n",
               counter_loc, f_stop, f_step, s->line);
    emit_linef(c, depth, "(local.set %s) (local.set %s) (local.set %s) (local.set %s)\n", f_skip, f_step, f_stop,
               counter_loc);
    ol_init_close(c, s, depth);
    char load_buf[80];
    snprintf(load_buf, sizeof(load_buf), "(local.get %s)", counter_loc);

    emit_linef(c, depth, "(block $brk_%d\n", label);
    emit_linef(c, depth + 1, "(br_if $brk_%d (local.get %s))\n", label, f_skip);
    emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
    ol_loop_header(c, s, depth + 2);
    /* Fresh per-iteration binding for a captured control variable. */
    if (boxed) {
        emit_linef(c, depth + 2, "(local.set $L%d (struct.new $Box %s))\n", slot, load_buf);
    }
    /* body */
    c->for_depth++;
    emit_block(c, &s->as.for_num.body, depth + 2);
    c->for_depth--;
    /* i = i + step, but stop if the integer addition wrapped past the
     * representable range (Lua 5.4 numeric-for overflow semantics) —
     * otherwise `for i = maxinteger-2, maxinteger` would loop forever. */
    emit_linef(c, depth + 2, "(local.set %s (call $lua_add %s (local.get %s)))\n", f_next, load_buf, f_step);
    emit_linef(c, depth + 2, "(br_if $brk_%d (call $for_overflowed %s (local.get %s) (local.get %s)))\n", label, load_buf,
               f_step, f_next);
    emit_linef(c, depth + 2, "(local.set %s (local.get %s))\n", counter_loc, f_next);
    /* Continue while the new value is within the limit. The entry test was
     * $for_prep's, so only later iterations compare here (a NaN float bound
     * runs the body once, as in reference Lua). */
    emit_linef(c, depth + 2, "(if (call $for_step_positive (local.get %s))\n"
                             "%*s  (then (br_if $brk_%d (i32.eqz (call $num_le %s (local.get %s)))))\n"
                             "%*s  (else (br_if $brk_%d (i32.eqz (call $num_le (local.get %s) %s)))))\n",
               f_step, 2 * (depth + 2), "", label, load_buf, f_stop, 2 * (depth + 2), "", label, f_stop, load_buf);
    emit_linef(c, depth + 2, "br $cont_%d\n", label);
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
}

static void emit_for_num(CG *c, const Stmt *s, int depth) {
    int label = c->next_label++;
    if (!push_break_label(c, label)) return;
    if (slot_is_int(c, s->as.for_num.local_idx)) emit_for_num_int(c, s, label, depth);
    else emit_for_num_boxed(c, s, label, depth);
    c->break_depth--;
}

static void emit_for_gen(CG *c, const Stmt *s, int depth) {
    /* Generic for: `for v1[, v2, ...] in iter [, state [, init]] do body end`.
     * Evaluate the expr_list into ($for_iter_any, $for_state, $for_k),
     * then loop: call iter(state, k); if first result is nil, break;
     * otherwise bind v1..vN to results, set k = result[0]. */
    int label = c->next_label++;
    if (!push_break_label(c, label)) return;
    /* Per-nesting-level iterator state so an inner for-loop can't
     * clobber this loop's iterator/state/control key. ($tmp_args is
     * recomputed each iteration, so it stays function-shared.) */
    int fd = c->for_depth;
    char f_iter[24], f_state[24], f_k[24];
    snprintf(f_iter, sizeof f_iter, "$for_iter_%d", fd);
    snprintf(f_state, sizeof f_state, "$for_state_%d", fd);
    snprintf(f_k, sizeof f_k, "$for_k_%d", fd);
    char f_v[24], f_mode[24], f_pos[24];
    snprintf(f_v, sizeof f_v, "$for_v_%d", fd);
    snprintf(f_mode, sizeof f_mode, "$for_mode_%d", fd);
    snprintf(f_pos, sizeof f_pos, "$for_pos_%d", fd);
    int n_exprs = s->as.for_gen.n_exprs;
    int n_names = s->as.for_gen.n_names;
    /* One or two variables over ipairs / pairs step in place, without
     * calling the iterator (see $for_gen_mode); any other iterator goes
     * through the call protocol. */
    int stepped = n_names <= 2;
    ol_init_open(c, s, depth);
    emit_line(c, depth, "(local.set $tmp_args\n");
    emit_args_array(c, s->as.for_gen.exprs, n_exprs, depth + 1);
    emit_line(c, depth, ")\n");
    /* iter = args[0]; state = args[1]; k = args[2]. */
    emit_linef(c, depth, "(local.set %s "
                         "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0)))\n",
               f_iter);
    emit_linef(c, depth, "(local.set %s "
                         "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 1)))\n",
               f_state);
    emit_linef(c, depth, "(local.set %s "
                         "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 2)))\n",
               f_k);
    /* The explist's 4th value is a to-be-closed "closing" value (Lua §3.3.5):
     * validate+push it now (after push_break_label recorded the pre-closing
     * depth, so `break` closes it too); close it when the loop exits. nil/false
     * (e.g. the common pairs/ipairs case) are accepted and never closed. */
    int for_close = for_gen_has_closing(s);
    int pre_close_base = c->close_count;
    if (for_close) {
        emit_line(c, depth, "(call $tbc_push (ref.as_non_null (local.get $tbc)) "
                            "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                            "(i32.const 3)))\n");
        c->close_count++;
    }

    /* Pre-allocate boxes (or just nil-init the local) per loop var. */
    for (int i = 0; i < s->as.for_gen.n_names; i++) {
        int li = s->as.for_gen.local_idxs[i];
        emit_indent(c, depth);
        if (slot_is_boxed(c, li)) {
            wat_appendf(c->w,
                        "(local.set $L%d (struct.new $Box (ref.null any)))\n", li);
        } else {
            wat_appendf(c->w, "(local.set $L%d (ref.null any))\n", li);
        }
    }

    if (stepped) {
        emit_linef(c, depth, "(call $for_gen_mode (local.get %s) (local.get %s) (local.get %s))\n", f_iter, f_state,
                   f_k);
        emit_linef(c, depth, "local.set %s\n", f_pos);
        emit_linef(c, depth, "local.set %s\n", f_mode);
    }
    ol_init_close(c, s, depth);

    emit_linef(c, depth, "(block $brk_%d\n", label);
    emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
    ol_loop_header(c, s, depth + 2);
    int d = depth + 2;
    if (stepped) {
        /* ipairs: the next index and t[i], probed inline; nil ends the loop */
        emit_linef(c, d, "(if (i32.eq (local.get %s) (i32.const 1))\n", f_mode);
        emit_line(c, d + 1, "(then\n");
        emit_linef(c, d + 2, "(local.set %s (i64.add (local.get %s) (i64.const 1)))\n", f_pos, f_pos);
        emit_linef(c, d + 2, "(local.set %s\n", f_v);
        if (c->opt_int) {
            int n = emit_ix_get_open(c, d + 3);
            emit_linef(c, d + 4, "(local.get %s) (local.get %s)\n", f_state, f_pos);
            emit_ix_get_close(c, n, NULL, s->line, d + 3);
        } else {
            emit_linef(c, d + 3, "(call $lua_index_ik (local.get %s) (local.get %s) (i32.const %d))\n", f_state, f_pos,
                       s->line);
        }
        emit_line(c, d + 2, ")\n");
        emit_linef(c, d + 2, "(br_if $brk_%d (ref.is_null (local.get %s)))\n", label, f_v);
        emit_linef(c, d + 2, "(local.set %s (call $make_int (local.get %s))))\n", f_k, f_pos);
        /* next: the entry at the carried position */
        emit_linef(c, d + 1, "(else (if (i32.eq (local.get %s) (i32.const 2))\n", f_mode);
        emit_line(c, d + 2, "(then\n");
        emit_linef(c, d + 3, "(call $next_step (ref.cast (ref $LuaTable) (local.get %s)) (local.get %s))\n", f_state,
                   f_pos);
        emit_linef(c, d + 3, "local.set %s\n", f_v);
        emit_linef(c, d + 3, "local.set %s\n", f_k);
        emit_linef(c, d + 3, "local.set %s\n", f_pos);
        emit_linef(c, d + 3, "(br_if $brk_%d (ref.is_null (local.get %s))))\n", label, f_k);
        emit_line(c, d + 2, "(else\n");
        d += 3;
    }
    if (n_names == 1) {
        /* One variable: the iterator's first result, through its fast entry. */
        emit_linef(c, d, "(local.set %s (call $lua_call1 (local.get %s) (local.get %s) (local.get %s)"
                         " (ref.null any) (ref.null any) (i32.const 2) (i32.const %d)))\n",
                   f_k, f_iter, f_state, f_k, s->line);
        emit_linef(c, d, "(br_if $brk_%d (ref.is_null (local.get %s)))\n", label, f_k);
    } else {
        /* Call iter(state, k). The iterator can be any callable (a closure,
         * or a table with __call) — go through $lua_call_any so a wrong type
         * produces a typed error instead of a trap. */
        emit_line(c, d, "(local.set $tmp_args\n");
        emit_line(c, d + 1, "(call $lua_call_any\n");
        emit_linef(c, d + 2, "(local.get %s)\n", f_iter);
        emit_linef(c, d + 2, "(array.new_fixed $ArgArr 2 (local.get %s) (local.get %s))\n", f_state, f_k);
        emit_linef(c, d + 2, "(i32.const %d)\n", s->line);
        emit_line(c, d + 1, ")\n");
        emit_line(c, d, ")\n");
        /* k = results[0]; nil ends the loop */
        emit_linef(c, d, "(local.set %s (call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0)))\n",
                   f_k);
        emit_linef(c, d, "(br_if $brk_%d (ref.is_null (local.get %s)))\n", label, f_k);
        if (stepped)
            emit_linef(c, d, "(local.set %s (call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 1)))\n",
                       f_v);
    }
    if (stepped) emit_line(c, depth + 2, "))))\n"); /* else, if, else, if */
    /* Bind loop vars from results. A captured var gets a FRESH $Box
     * each iteration so closures over it see distinct values
     * (Lua 5.4+ semantics), rather than sharing one mutated cell. */
    for (int i = 0; i < n_names; i++) {
        int li = s->as.for_gen.local_idxs[i];
        char src[96];
        if (i == 0) snprintf(src, sizeof src, "(local.get %s)", f_k);
        else if (stepped) snprintf(src, sizeof src, "(local.get %s)", f_v);
        else snprintf(src, sizeof src, "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const %d))", i);
        if (slot_is_boxed(c, li)) emit_linef(c, depth + 2, "(local.set $L%d (struct.new $Box %s))\n", li, src);
        else emit_linef(c, depth + 2, "(local.set $L%d %s)\n", li, src);
    }
    /* body */
    c->for_depth++;
    emit_block(c, &s->as.for_gen.body, depth + 2);
    c->for_depth--;
    emit_linef(c, depth + 2, "br $cont_%d\n", label);
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
    /* Loop exited normally (iterator returned nil) — close the closing value.
     * break already closed it (down to pre_close_base) before branching here,
     * so this is a no-op on that path; an error/goto exit closed it via $tbc. */
    if (for_close) {
        emit_close_upto(c, pre_close_base, "(ref.null any)", depth);
        c->close_count = pre_close_base;
    }
    c->break_depth--;
}

/* ----- statements ----- */
/* `local n1, n2, ... = v1, v2, ...`: the values evaluated left to right and
 * stored by slot type, a trailing call / `...` spread over the names left
 * after the leading values, missing values nil; then each <close> name is
 * registered with the to-be-closed stack. */
static void emit_local_stmt(CG *c, const Stmt *s, int depth) {
    int n_names = s->as.local.n_names;
    int n_values = s->as.local.n_values;
    /* A trailing call / `...` only spreads when names remain after it;
     * otherwise only its first value (or none) is used, so it is a
     * single value like the rest (`local x = f()` takes the call's
     * single-value entry). */
    int last_call = (n_values > 0 && n_names > n_values &&
                     is_multival_tail(s->as.local.values[n_values - 1]));
    /* Count of leading single-valued source expressions: everything but
     * a trailing multivalue tail. Lua evaluates the value list strictly
     * left-to-right, so these are emitted *before* the trailing tail. */
    int n_lead = last_call ? n_values - 1 : n_values;
    /* 1. Leading single values, in source order. A value with a matching
     *    name is assigned to its slot; an excess value is still evaluated
     *    for its side effects (e.g. an __index trigger) and dropped. */
    for (int i = 0; i < n_lead; i++) {
        if (i >= n_names) {
            emit_expr(c, s->as.local.values[i], depth);
            emit_line(c, depth, "drop\n");
            continue;
        }
        int slot = s->as.local.local_idxs[i];
        if (slot_is_ibox(c, slot)) { /* a fresh int box per declaration */
            emit_linef(c, depth, "(local.set $L%d (struct.new $IBox (ref.null any)\n", slot);
            emit_int_expr(c, s->as.local.values[i], depth + 1);
            emit_line(c, depth, "))\n");
            continue;
        }
        if (emit_typed_slot_store(c, slot, s->as.local.values[i], depth)) continue;
        emit_local_init_open(c, slot, depth);
        emit_expr(c, s->as.local.values[i], depth + 1);
        emit_local_init_close(c, slot, depth);
    }
    /* 2. Trailing multivalue tail, evaluated *after* the leading values
     *    and spread across the remaining names (and evaluated even when
     *    no name consumes it). Spread slots are never int/float-
     *    specialized (the analysis only specializes single literal/int
     *    initializers), so the boxed/anyref path covers them. */
    if (last_call) {
        emit_line(c, depth, "(local.set $tmp_args\n");
        emit_multival_array(c, s->as.local.values[n_values - 1], depth + 1);
        emit_line(c, depth, ")\n");
        for (int i = n_lead; i < n_names; i++) {
            int slot = s->as.local.local_idxs[i];
            emit_local_init_open(c, slot, depth);
            emit_args_at(c, i - n_lead, depth + 1);
            emit_local_init_close(c, slot, depth);
        }
    } else {
        /* 3. No trailing tail: names past the value list get nil. */
        for (int i = n_lead; i < n_names; i++) {
            int slot = s->as.local.local_idxs[i];
            int boxed = slot_is_boxed(c, slot);
            emit_linef(c, depth, boxed ? "(local.set $L%d (struct.new $Box (ref.null "
                                         "any)))\n"
                                       : "(local.set $L%d (ref.null any))\n",
                       slot);
        }
    }
    /* <close> declarations: push each onto the per-activation to-be-closed
     * stack. $tbc_push validates closability at the declaration (matching
     * reference Lua: a truthy value with no __close is rejected here, not
     * at scope exit; nil/false are accepted and never closed). close_count
     * tracks the live depth for the enclosing block / break / goto / return
     * close targets. */
    if (s->as.local.attribs) {
        for (int i = 0; i < n_names; i++) {
            if (s->as.local.attribs[i] != 2) continue;
            int slot = s->as.local.local_idxs[i];
            emit_indent(c, depth);
            if (slot_is_boxed(c, slot))
                wat_appendf(c->w,
                            "(call $tbc_push (ref.as_non_null (local.get $tbc)) "
                            "(struct.get $Box $v (local.get $L%d)))\n",
                            slot);
            else
                wat_appendf(c->w,
                            "(call $tbc_push (ref.as_non_null (local.get $tbc)) "
                            "(local.get $L%d))\n",
                            slot);
            c->close_count++;
        }
    }
}

/* A call as a statement: its results are dropped, so a direct call takes
 * the single-value entry and a dynamic one the fast entry when they apply;
 * otherwise get the result array and drop it. */
static void emit_call_stmt(CG *c, const Stmt *s, int depth) {
    const Expr *ce = s->as.expr_stmt.expr;
    const LuaFunc *dt = ce->kind == EXPR_CALL ? direct_call_target(c, ce) : NULL;
    if (dt && direct_args_typed_ok(c, ce, dt)) emit_typed_direct_call1(c, ce, dt, depth);
    else if (fast_call_nargs(c, ce) >= 0) emit_fast_call(c, ce, depth);
    else emit_call_array(c, ce, depth);
    emit_line(c, depth, "drop\n");
}

static void emit_while(CG *c, const Stmt *s, int depth) {
    int label = c->next_label++;
    if (!push_break_label(c, label)) return;
    emit_linef(c, depth, "(block $brk_%d\n", label);
    emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
    ol_loop_header(c, s, depth + 2);
    emit_truthy(c, s->as.while_stmt.cond, depth + 2);
    emit_line(c, depth + 2, "i32.eqz\n");
    emit_linef(c, depth + 2, "br_if $brk_%d\n", label);
    emit_block(c, &s->as.while_stmt.body, depth + 2);
    emit_linef(c, depth + 2, "br $cont_%d\n", label);
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
    c->break_depth--;
}

static void emit_repeat(CG *c, const Stmt *s, int depth) {
    int label = c->next_label++;
    if (!push_break_label(c, label)) return;
    emit_linef(c, depth, "(block $brk_%d\n", label);
    emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
    ol_loop_header(c, s, depth + 2);
    /* A <close> var declared in the body stays in scope for the until
     * condition and is closed AFTER it (Lua §3.3.5). Emit the body
     * statements directly (emit_block would close at the body's end),
     * evaluate the condition, then close the body's to-be-closed vars.
     * $close_upto is a stack-neutral folded call, so it can sit between the
     * condition's i32 result and the br_if that consumes it. */
    int rbase = c->close_count;
    emit_block_stmts(c, &s->as.repeat.body, depth + 2);
    emit_truthy(c, s->as.repeat.cond, depth + 2);
    emit_line(c, depth + 2, "i32.eqz\n");
    if (c->close_count > rbase)
        emit_close_upto(c, rbase, "(ref.null any)", depth + 2);
    c->close_count = rbase;
    emit_linef(c, depth + 2, "br_if $cont_%d\n", label);
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
    c->break_depth--;
}

static void emit_break(CG *c, const Stmt *s, int depth) {
    if (c->break_depth == 0) {
        cg_error(c, "break outside loop");
        return;
    }
    int label = c->break_labels[c->break_depth - 1];
    /* Close to-be-closed locals declared inside this loop before leaving. */
    int base = c->break_close_count[c->break_depth - 1];
    if (c->close_count > base) emit_close_upto(c, base, "(ref.null any)", depth);
    emit_linef(c, depth, "br $brk_%d\n", label);
}

static void emit_goto(CG *c, const Stmt *s, int depth) {
    /* Dispatch lowering: set the target block's $next, then re-enter
     * its dispatch loop. The local and label are function-scoped, so
     * this works from inside arbitrarily nested blocks/loops. Before
     * leaving, close any to-be-closed vars whose scope the jump exits
     * (down to the count live at the target label). */
    if (c->close_count > s->as.label.close_base)
        emit_close_upto(c, s->as.label.close_base, "(ref.null any)", depth);
    emit_linef(c, depth, "(local.set $next_%d (i32.const %d))\n",
               s->as.label.block_dispatch_id, s->as.label.target_segment_idx);
    emit_linef(c, depth, "(br $dispatch_%d)\n", s->as.label.block_dispatch_id);
}

/* `global n1, ... = v1, ...`: like `local`, but each name is a field of
 * $g_globals. */
static void emit_global_decl(CG *c, const Stmt *s, int depth) {
    int n_names = s->as.global_decl.n_names;
    int n_values = s->as.global_decl.n_values;
    if (n_values == 0) return;
    int last_call = (n_values > 0 &&
                     is_multival_tail(s->as.global_decl.values[n_values - 1]));
    int n_lead = last_call ? n_values - 1 : n_values;
    /* Same left-to-right evaluation contract as STMT_LOCAL: leading
     * single values first, then the trailing multivalue tail. The store
     * keys are constant strings (no side effects), so only the value
     * order matters. */
    for (int i = 0; i < n_lead; i++) {
        if (i >= n_names) {
            emit_expr(c, s->as.global_decl.values[i], depth);
            emit_line(c, depth, "drop\n");
            continue;
        }
        int gi = s->as.global_decl.global_idxs[i];
        emit_line(c, depth, "(call $tab_set (ref.as_non_null (global.get $g_globals))\n");
        emit_indent(c, depth + 1);
        emit_global_key(c, c->pr->globals.items[gi].name,
                        c->pr->globals.items[gi].name_len);
        emit_expr(c, s->as.global_decl.values[i], depth + 1);
        emit_line(c, depth, ")\n");
    }
    if (last_call) {
        emit_line(c, depth, "(local.set $tmp_args\n");
        emit_multival_array(c, s->as.global_decl.values[n_values - 1], depth + 1);
        emit_line(c, depth, ")\n");
    }
    for (int i = n_lead; i < n_names; i++) {
        int gi = s->as.global_decl.global_idxs[i];
        emit_line(c, depth, "(call $tab_set (ref.as_non_null (global.get $g_globals))\n");
        emit_indent(c, depth + 1);
        emit_global_key(c, c->pr->globals.items[gi].name,
                        c->pr->globals.items[gi].name_len);
        if (last_call) {
            emit_args_at(c, i - n_lead, depth + 1);
        } else {
            emit_line(c, depth + 1, "(ref.null any)\n");
        }
        emit_line(c, depth, ")\n");
    }
}

static void emit_if(CG *c, const Stmt *s, int depth) {
    int label = c->next_label++;
    emit_linef(c, depth, "(block $if_end_%d\n", label);
    for (size_t i = 0; i < s->as.if_stmt.narms; i++) {
        IfArm *a = &s->as.if_stmt.arms[i];
        emit_truthy(c, a->cond, depth + 1);
        emit_line(c, depth + 1, "(if (then\n");
        emit_block(c, &a->body, depth + 2);
        emit_linef(c, depth + 2, "br $if_end_%d\n", label);
        emit_line(c, depth + 1, "))\n");
    }
    if (s->as.if_stmt.has_else) {
        emit_block(c, &s->as.if_stmt.else_body, depth + 1);
    }
    emit_line(c, depth, ")\n");
}

static void emit_local_func(CG *c, const Stmt *s, int depth) {
    int slot = s->as.local_func.local_idx;
    int boxed = slot_is_boxed(c, slot);
    /* If the slot is captured (e.g. by the closure itself for
     * recursion), pre-allocate the box with nil so the function body
     * can see its own slot; then store the closure into the box.
     * If not captured, simply build the closure and store it. */
    if (boxed) {
        emit_linef(c, depth, "(local.set $L%d (struct.new $Box (ref.null any)))\n", slot);
        emit_line(c, depth, "(struct.set $Box $v\n");
        emit_linef(c, depth + 1, "(local.get $L%d)\n", slot);
        emit_function_expr(c, s->as.local_func.func, depth + 1);
        emit_line(c, depth, ")\n");
    } else {
        emit_linef(c, depth, "(local.set $L%d\n", slot);
        emit_function_expr(c, s->as.local_func.func, depth + 1);
        emit_line(c, depth, ")\n");
    }
}

void emit_stmt(CG *c, const Stmt *s, int depth) {
    if (!c->ok) return;
    if (stmt_is_loop(s) && emit_outlined_loop(c, s, depth)) return;
    switch (s->kind) {
    case STMT_LOCAL: emit_local_stmt(c, s, depth); break;
    case STMT_ASSIGN: emit_assign(c, s, depth); break;
    case STMT_EXPR: emit_call_stmt(c, s, depth); break;
    case STMT_DO: emit_block(c, &s->as.do_stmt.body, depth); break;
    case STMT_RETURN: emit_return(c, s, depth); break;
    case STMT_WHILE: emit_while(c, s, depth); break;
    case STMT_REPEAT: emit_repeat(c, s, depth); break;
    case STMT_BREAK: emit_break(c, s, depth); break;
    case STMT_GOTO: emit_goto(c, s, depth); break;
    case STMT_LABEL: break; /* its wrappers come from emit_block; no code at its position */
    case STMT_FOR_NUM: emit_for_num(c, s, depth); break;
    case STMT_FOR_GEN: emit_for_gen(c, s, depth); break;
    case STMT_GLOBAL: emit_global_decl(c, s, depth); break;
    case STMT_IF: emit_if(c, s, depth); break;
    case STMT_LOCAL_FUNC: emit_local_func(c, s, depth); break;
    }
}

/* Count <close> declarations at this block level (not in nested blocks). */
static int count_block_close(const Block *b) {
    int n = 0;
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *s = b->items[i];
        if (s->kind != STMT_LOCAL || !s->as.local.attribs) continue;
        for (int j = 0; j < s->as.local.n_names; j++)
            if (s->as.local.attribs[j] == 2) n++;
    }
    return n;
}

/* A generic-for's iterator explist yields a 4th "closing" value that is
 * to-be-closed (Lua §3.3.5). It is present only when the explist can produce a
 * 4th value: an explicit 4th expression, or a trailing call/vararg that might
 * expand to one. */
static int for_gen_has_closing(const Stmt *s) {
    int n = s->as.for_gen.n_exprs;
    if (n >= 4) return 1;
    return n >= 1 && is_multival_tail(s->as.for_gen.exprs[n - 1]);
}

/* Count every to-be-closed slot reachable in this function's body (each <close>
 * declaration, plus each generic-for closing value), NOT descending into nested
 * function bodies. An upper bound on the simultaneously live count, used to
 * pre-size the $tbc backing array. */
static void count_close_in(const Block *b, void *ctx) {
    int *n = ctx;
    *n += count_block_close(b);
    for (size_t i = 0; i < b->count; i++) {
        if (b->items[i]->kind == STMT_FOR_GEN) *n += for_gen_has_closing(b->items[i]);
        for_each_nested_block(b->items[i], count_close_in, ctx);
    }
}
static int count_fn_close(const Block *b) {
    int n = 0;
    count_close_in(b, &n);
    return n;
}

/* Emit a close of the to-be-closed stack down to `target`, with the given 2nd
 * __close argument (null on a structured exit). */
static void emit_close_upto(CG *c, int target, const char *err_wat, int depth) {
    emit_linef(c, depth, "(call $close_upto (ref.as_non_null (local.get $tbc)) "
                         "(i32.const %d) %s)\n",
               target, err_wat);
}

/* The locals and prologue a function/main body needs for <close> support:
 * the per-activation $tbc stack and a snapshot of call_depth at entry (so the
 * error catch can run __close at the right depth). Only emitted when the body
 * actually declares a to-be-closed variable. */
static void emit_tbc_locals(WatBuilder *w, int has_close) {
    if (!has_close) return;
    wat_append(w, "    (local $tbc (ref null $Tbc))\n");
    wat_append(w, "    (local $close_depth i32)\n");
}

static void emit_tbc_init(WatBuilder *w, int n_total) {
    wat_appendf(w, "    (local.set $tbc (struct.new $Tbc (array.new $ArgArr "
                   "(ref.null any) (i32.const %d)) (i32.const 0)))\n",
                n_total);
    wat_append(w, "    (local.set $close_depth (global.get $call_depth))\n");
}

/* Emit a function/main body. With to-be-closed vars, wrap it in one
 * function-level error catch: structured exits (return/break/goto/fall-through)
 * drain the $tbc stack themselves; an error unwind lands here, restores the
 * entry depth, closes whatever is still open with the error object, and
 * rethrows (via $close_upto, which always throws when given an error). */
static void emit_close_body(CG *c, const Block *body, int has_close, int depth) {
    c->close_count = 0;
    if (!has_close) {
        emit_block(c, body, depth);
        return;
    }
    int L = c->next_label++;
    emit_linef(c, depth, "(block $fnclose_done_%d\n", L);
    emit_linef(c, depth + 1, "(block $fnclose_catch_%d (result anyref)\n", L);
    emit_linef(c, depth + 2, "(try_table (catch $LuaError $fnclose_catch_%d)\n", L);
    emit_block(c, body, depth + 3);
    emit_line(c, depth + 2, ")\n"); /* try_table */
    emit_linef(c, depth + 2, "(br $fnclose_done_%d)\n", L);
    emit_line(c, depth + 1, ")\n"); /* fnclose_catch: caught error value on stack */
    emit_line(c, depth + 1, "(local.set $tmp_any)\n");
    emit_line(c, depth + 1, "(global.set $call_depth (local.get $close_depth))\n");
    emit_line(c, depth + 1, "(call $close_upto (ref.as_non_null (local.get $tbc)) "
                            "(i32.const 0) (local.get $tmp_any))\n");
    emit_line(c, depth + 1, "(unreachable)\n");
    emit_line(c, depth, ")\n"); /* fnclose_done */
}

/* Emit a goto-able block as a dispatch table:
 *
 *   (block $exit_BID
 *     (loop  $dispatch_BID
 *       (block $seg_BID_N
 *         …
 *         (block $seg_BID_1
 *           (block $seg_BID_0
 *             (br_table $seg_BID_0 $seg_BID_1 … $seg_BID_N $exit_BID
 *                       (local.get $next_BID))
 *           )
 *           <segment 0 body>
 *           (local.set $next_BID 1) (br $dispatch_BID)
 *         )
 *         <segment 1 body>
 *         (local.set $next_BID 2) (br $dispatch_BID)
 *       )
 *       …
 *       <segment N body>
 *       (br $exit_BID)
 *     )
 *   )
 *
 * Where BID is the block's dispatch id (= id of the first label declared
 * in it). Segments are: segment 0 = the stmts before the first label;
 * segment k (1..N) = the stmts at label k (after the label itself). A
 * goto to a label in this block becomes
 *     (local.set $next_BID K) (br $dispatch_BID)
 * — and the same shape works for jumps OUT of nested blocks because the
 * $next_BID local is function-scoped and $dispatch_BID is just a label
 * br can traverse through.
 *
 * This handles every label graph including interleaved forward+backward
 * scopes (the original cross-label-overlap case the old nested-blocks
 * lowering had to bail out on). */
/* Emit a block's statements (label dispatch and all), WITHOUT any <close>
 * handling — emit_block wraps this with the scope push/close calls. */
static void emit_block_stmts(CG *c, const Block *b, int depth) {
    /* Fast path: no labels in this block, no wrappers needed. */
    int has_labels = 0;
    for (size_t i = 0; i < b->count; i++) {
        if (b->items[i]->kind == STMT_LABEL) {
            has_labels = 1;
            break;
        }
    }
    if (!has_labels) {
        for (size_t i = 0; i < b->count; i++) emit_stmt(c, b->items[i], depth);
        return;
    }

    /* Compute segment boundaries: seg_start[k] = index of the first stmt
     * in segment k (k = 0..N). Segment 0 starts at 0; segment k>=1 starts
     * at the position AFTER the k-th label statement. */
    int seg_start[MAX_BLOCK_LABELS + 1]; /* one slot per label + sentinel */
    int N = 0;
    int bid = -1;
    seg_start[0] = 0;
    for (size_t i = 0; i < b->count; i++) {
        Stmt *st = b->items[i];
        if (st->kind != STMT_LABEL) continue;
        if (N == 0) bid = st->as.label.block_dispatch_id;
        N++;
        if (N >= MAX_BLOCK_LABELS) {
            cg_error(c, "too many labels in one block (limit 64)");
            return;
        }
        seg_start[N] = (int)i + 1;
    }
    int seg_end_N = (int)b->count; /* end of segment N */

    /* Reset the dispatch state on entry: $next_BID is a function-scoped
     * local, so a previous entry (e.g. a previous iteration of an
     * enclosing for-loop) would otherwise leave us pointing at the wrong
     * segment. */
    emit_linef(c, depth, "(local.set $next_%d (i32.const 0))\n", bid);
    /* Outer (block $exit_BID) — natural fall-through and gotos exit here. */
    emit_linef(c, depth, "(block $exit_%d\n", bid);
    /* Dispatch loop — backward jumps go through here. */
    emit_linef(c, depth + 1, "(loop $dispatch_%d\n", bid);

    /* Open N+1 nested (block $seg_BID_k …) from outermost (k=N) to innermost (k=0). */
    for (int k = N; k >= 0; k--) {
        emit_linef(c, depth + 2 + (N - k), "(block $seg_%d_%d\n", bid, k);
    }
    /* Innermost: the br_table. Targets in order: seg_0, seg_1, …, seg_N, exit. */
    emit_line(c, depth + 3 + N, "(br_table");
    for (int k = 0; k <= N; k++) wat_appendf(c->w, " $seg_%d_%d", bid, k);
    wat_appendf(c->w, " $exit_%d (local.get $next_%d))\n", bid, bid);
    /* Close the innermost block ($seg_BID_0). */
    emit_line(c, depth + 2 + N, ")\n");

    /* Emit segment 0..N bodies. After each segment's closing paren of its
     * own (block) wrapper, we are at depth = depth + 2 + (N-k) — i.e. for
     * segment k we sit "between" the close of $seg_BID_k and the close of
     * $seg_BID_{k+1}. */
    for (int k = 0; k <= N; k++) {
        int body_depth = depth + 2 + (N - k);
        int start = seg_start[k];
        int end = (k < N) ? seg_start[k + 1] - 1 /* skip the label stmt */
                          : seg_end_N;
        for (int i = start; i < end; i++) {
            Stmt *st = b->items[i];
            if (st->kind == STMT_LABEL) continue; /* labels are markers, not code */
            emit_stmt(c, st, body_depth);
        }
        if (k < N) {
            /* Fall through to segment k+1 by re-entering the dispatch. */
            emit_linef(c, body_depth, "(local.set $next_%d (i32.const %d))\n", bid, k + 1);
            emit_linef(c, body_depth, "(br $dispatch_%d)\n", bid);
            /* Close the surrounding $seg_BID_{k+1} block now that this
             * segment's body is complete. */
            emit_line(c, body_depth - 1, ")\n");
        } else {
            /* Last segment: natural exit from the dispatched block. */
            emit_linef(c, body_depth, "(br $exit_%d)\n", bid);
        }
    }
    /* Close the loop and outer block. */
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
}

/* Emit a block, applying <close> semantics. A block with no to-be-closed
 * locals is just its statements. Otherwise its <close> declarations push onto
 * the per-activation $tbc stack as they execute (STMT_LOCAL), and on normal
 * fall-through we close the block's own vars (down to the count that was live
 * on entry). Errors, returns, breaks and gotos are closed by those exit paths
 * directly via $close_upto — all draining the same stack, so each var is
 * closed exactly once. */
static void emit_block(CG *c, const Block *b, int depth) {
    if (count_block_close(b) == 0) {
        emit_block_stmts(c, b, depth);
        return;
    }
    int base = c->close_count;
    emit_block_stmts(c, b, depth);
    /* STMT_LOCAL bumped close_count for each <close> it emitted; close them. */
    if (c->close_count > base) emit_close_upto(c, base, "(ref.null any)", depth);
    c->close_count = base;
}

/* Walk a block body collecting dispatch ids of every block-with-labels.
 * Output is the set of distinct ids (no duplicates because each block's
 * dispatch id is uniquely the id of its first label). On overflow this raises
 * a codegen error rather than dropping ids — a dropped id would leave its
 * $next_<id> local undeclared, producing invalid WAT. */
typedef struct {
    CG *c;
    int *out, *n, cap;
} DispatchIds;
static void collect_dispatch_ids_in(const Block *b, void *ctx) {
    DispatchIds *d = ctx;
    /* Find the first label in this block (if any) — its id is the dispatch id. */
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *st = b->items[i];
        if (st->kind == STMT_LABEL) {
            if (*d->n >= d->cap) {
                cg_error(d->c, "too many label-bearing blocks in one function");
                return;
            }
            d->out[(*d->n)++] = st->as.label.block_dispatch_id;
            break;
        }
    }
    for (size_t i = 0; i < b->count && d->c->ok; i++) for_each_nested_block(b->items[i], collect_dispatch_ids_in, d);
}
static void collect_dispatch_ids(CG *c, const Block *b, int *out, int *n, int cap) {
    collect_dispatch_ids_in(b, &(DispatchIds){c, out, n, cap});
}

/* Deepest nesting of numeric/generic for-loops in a block. Each for-loop
 * adds one level; other compound statements pass their inner depth through
 * unchanged (only for-loops own $for_* scratch). The result sizes the
 * per-level scratch declarations in the function prologue. */
static void max_for_nesting_in(const Block *b, void *ctx);
static int max_for_nesting(const Block *b) {
    int best = 0;
    if (!b) return 0;
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *s = b->items[i];
        int d = 0;
        for_each_nested_block(s, max_for_nesting_in, &d);
        if (s->kind == STMT_FOR_NUM || s->kind == STMT_FOR_GEN) d++;
        if (d > best) best = d;
    }
    return best;
}
static void max_for_nesting_in(const Block *b, void *ctx) {
    int *d = ctx, v = max_for_nesting(b);
    if (v > *d) *d = v;
}

static void note_for_gen(const Stmt *s, void *ctx) {
    if (s->kind == STMT_FOR_GEN) *(int *)ctx = 1;
}

/* Emit the per-level $for_* scratch locals for a function body (a generic
 * for's stepping state only when the body has one). */
static void emit_for_scratch_locals(WatBuilder *w, const Block *body) {
    int levels = max_for_nesting(body), gen = 0;
    walk_stmts(body, note_for_gen, &gen);
    for (int d = 0; d < levels; d++) {
        wat_appendf(w,
                    "    (local $for_stop_%d anyref) (local $for_step_%d anyref)"
                    " (local $for_next_%d anyref) (local $for_cur_%d anyref)"
                    " (local $for_skip_%d i32)\n",
                    d, d, d, d, d);
        wat_appendf(w,
                    "    (local $for_iter_%d anyref) (local $for_state_%d anyref)"
                    " (local $for_k_%d anyref)\n",
                    d, d, d);
        if (gen)
            wat_appendf(w, "    (local $for_v_%d anyref) (local $for_mode_%d i32) (local $for_pos_%d i64)\n", d, d, d);
    }
}

/* ----- function bodies -----
 * Each wasm entry of a Lua function, and $main, compiles a body the same way:
 * analyse it, declare its locals, bind the parameters (or, in $main, set up
 * the runtime), give every captured local a placeholder box, then emit the
 * statements. */

Body function_body(const CG *c, const LuaFunc *fn) {
    return (Body){
        .body = &fn->body,
        .n_locals = fn->n_locals,
        .n_params = fn->n_params,
        .captured = fn->captured,
        .func_idx = fn->func_idx,
        .func_slot = c->bind_slot ? c->bind_slot[fn->func_idx] : NULL,
        .upval_func = c->bind_upval ? c->bind_upval[fn->func_idx] : NULL,
        .is_vararg = fn->is_vararg,
    };
}

/* Make `b` the current body: run the slot analyses (seeding typed parameters
 * from `param_seed`), size the lowering temporaries, and run the goto/label
 * pre-pass, which assigns the dispatch ids body_declare_locals declares. */
void body_begin(CG *c, Body *b, const NumTy *param_seed) {
    c->cur_captured = b->captured;
    c->cur_n_locals = b->n_locals;
    c->cur_n_params = b->n_params;
    c->cur_func_idx = b->func_idx;
    c->cur_func_slot = b->func_slot;
    c->cur_upval_func = b->upval_func;
    c->cur_is_int = c->cur_is_float = c->cur_is_maybe = NULL;
    b->isint = b->isfloat = b->ismaybe = NULL;
    b->ibox = ibox_row(c, b->func_idx);
    if (c->opt_int) {
        /* The analyses recognize direct calls (expr_is_int on EXPR_CALL needs
         * the binding maps, set just above), so a slot assigned the result of
         * an int-returning call is itself typed int. */
        size_t n = (size_t)b->n_locals;
        b->isint = xcalloc(n, 1);
        compute_int_slots(c, b->body, b->n_locals, b->n_params, b->captured, b->isint, param_seed);
        c->cur_is_int = b->isint;
        b->isfloat = xcalloc(n, 1);
        compute_float_slots(c, b->body, b->n_locals, b->n_params, b->captured, b->isfloat, param_seed);
        c->cur_is_float = b->isfloat;
        b->ismaybe = xcalloc(n, 1);
        compute_maybe_slots(c, b->body, b->n_locals, b->n_params, b->captured, b->ismaybe);
        c->cur_is_maybe = b->ismaybe;
    }
    c->mt_depth = 0;
    /* Lowering also fires on opaque operands with no maybe slot in sight, so
     * the temporaries are sized whenever the specializer is on. */
    c->mt_max = c->opt_int ? block_temp_need(c, b->body) : 0;
    c->next_label_id = 0;
    la_close_bases(b->body, 0);
    la_block(c, b->body, NULL);
    b->n_close = count_fn_close(b->body);
    b->outline = body_runs_once(c, b);
    c->cur_body = b;
}

/* Declare the body's wasm locals: one per slot (typed, maybe-typed, boxed or
 * plain), the lowering temporaries, the call and assignment scratch, the fast
 * entry's argument registers, the to-be-closed and for-loop bookkeeping, the
 * vararg array, and one dispatch index per label-bearing block. */
void body_declare_locals_of(CG *c, const Body *b, const unsigned char *slots, int fast, int vararg) {
    WatBuilder *w = c->w;
    for (int i = 0; i < b->n_locals; i++) {
        if (slots && !slots[i]) continue;
        switch (slot_rep(b, i)) {
        case REP_I64: wat_appendf(w, "    (local $L%d i64)\n", i); break;
        case REP_F64: wat_appendf(w, "    (local $L%d f64)\n", i); break;
        case REP_MAYBE:
            wat_appendf(w, "    (local $L%d anyref) (local $Lt%d i32) (local $Li%d i64) (local $Lf%d f64)\n",
                        i, i, i, i);
            break;
        case REP_BOX: wat_appendf(w, "    (local $L%d (ref $Box))\n", i); break;
        case REP_IBOX: wat_appendf(w, "    (local $L%d (ref $IBox))\n", i); break;
        case REP_ANY: wat_appendf(w, "    (local $L%d anyref)\n", i); break;
        }
    }
    for (int k = 0; k < c->mt_max; k++)
        wat_appendf(w, "    (local $mt%d anyref) (local $mg%d i32) (local $mi%d i64) (local $mf%d f64)\n",
                    k, k, k, k);
    wat_append(w, "    (local $tmp_any anyref)\n"
                  "    (local $tmp_args (ref null $ArgArr))\n"
                  "    (local $tmp_clo (ref null $LuaClosure))\n"
                  "    (local $tmp_callee anyref)\n"
                  "    (local $tmp_tab (ref null $LuaTable))\n"
                  "    (local $tmp_lhs_t (ref null $ArgArr))\n"
                  "    (local $tmp_lhs_k (ref null $ArgArr))\n");
    if (c->opt_int) emit_ix_locals(w);
    if (fast) wat_append(w, "    (local $ta0 anyref) (local $ta1 anyref) (local $ta2 anyref) (local $ta3 anyref)\n");
    emit_tbc_locals(w, b->n_close > 0);
    emit_for_scratch_locals(w, b->body);
    if (c->opt_int) {
        int lv = max_for_nesting(b->body);
        for (int d = 0; d < lv; d++)
            wat_appendf(w, "    (local $ifor_stop_%d i64) (local $ifor_step_%d i64)"
                           " (local $ifor_next_%d i64)\n",
                        d, d, d);
    }
    /* Non-null: the prologue always writes $varargs before first use. */
    if (vararg) wat_append(w, "    (local $varargs (ref $ArgArr))\n");
    /* One i32 per dispatch block, which STMT_GOTO sets and emit_block's
     * br_table reads. Default zero: the first dispatch lands in segment 0. */
    int bids[MAX_DISPATCH_IDS];
    int n = 0;
    collect_dispatch_ids(c, b->body, bids, &n, MAX_DISPATCH_IDS);
    for (int i = 0; i < n; i++) wat_appendf(w, "    (local $next_%d i32)\n", bids[i]);
}

void body_declare_locals(CG *c, const Body *b, int fast, int vararg) {
    body_declare_locals_of(c, b, NULL, fast, vararg);
    /* The caller's side of an outlined loop: its status, and what a `return`
     * inside it hands back. */
    if (b->outline) {
        const char *rt = ol_ret_type(c);
        wat_append(c->w, "    (local $olc_st i32)\n");
        if (rt) wat_appendf(c->w, "    (local $olc_ret %s)\n", rt);
    }
}

/* Box the captured locals, set up the to-be-closed bookkeeping and emit the
 * statements (after the parameters are bound). */
void body_emit(CG *c, const Body *b) {
    /* Initialise every captured local that isn't a parameter to a
     * placeholder $Box. Lua semantics guarantees a local's declaration
     * runs before any reference, but with dispatch-table goto lowering
     * the wasm validator can't always prove that statically. A placeholder
     * keeps the slot non-null; the real `local x = …` statement replaces
     * the box, and any closure captured at that point holds the fresh
     * one — no observable difference from the old eager-only-on-decl scheme. */
    for (int i = b->n_params; i < b->n_locals; i++)
        if (b->captured && b->captured[i]) wat_appendf(c->w, "    (local.set $L%d %s)\n", i, box_placeholder(b, i));
    if (b->n_close > 0) emit_tbc_init(c->w, b->n_close);
    if (c->ok) emit_close_body(c, b->body, b->n_close > 0, 2);
}

void body_end(CG *c, Body *b) {
    free(b->isint);
    free(b->isfloat);
    free(b->ismaybe);
    c->cur_is_int = c->cur_is_float = c->cur_is_maybe = NULL;
    c->cur_captured = NULL;
    c->cur_n_locals = c->cur_n_params = 0;
    c->cur_func_idx = -1;
    c->cur_func_slot = c->cur_upval_func = NULL;
    c->mt_max = c->mt_depth = 0;
    c->cur_body = NULL;
}
