/* Maybe-typed lowering (docs/design/22-maybe-typed-locals.md): arithmetic and
 * comparisons switched on the tag of (tag, i64, f64, anyref) cells, and the
 * inline math builtins. */
#include "internal.h"

/* A cell over four locals: <t><n> (the tag), <i><n>, <f><n> and <b><n>. */
static MCell mcell_locals(const char *t, const char *i, const char *f, const char *b, int n) {
    MCell m = {0};
    snprintf(m.st, sizeof m.st, "%s%d", t, n);
    snprintf(m.si, sizeof m.si, "%s%d", i, n);
    snprintf(m.sf, sizeof m.sf, "%s%d", f, n);
    snprintf(m.sb, sizeof m.sb, "%s%d", b, n);
    snprintf(m.t, sizeof m.t, "(local.get %s)", m.st);
    snprintf(m.i, sizeof m.i, "(local.get %s)", m.si);
    snprintf(m.f, sizeof m.f, "(local.get %s)", m.sf);
    snprintf(m.b, sizeof m.b, "(local.get %s)", m.sb);
    return m;
}
/* Maybe slot s: $Lt<s> $Li<s> $Lf<s> $L<s>. */
MCell mcell_slot(int s) { return mcell_locals("$Lt", "$Li", "$Lf", "$L", s); }
/* Lowering temporary k: $mg<k> $mi<k> $mf<k> $mt<k>. */
MCell mcell_tmp(int k) { return mcell_locals("$mg", "$mi", "$mf", "$mt", k); }

/* An immediate of a fixed tag: constant parts, no write targets. */
static MCell mcell_imm(int tag) {
    MCell m = {.static_tag = tag};
    snprintf(m.t, sizeof m.t, "(i32.const %d)", tag);
    snprintf(m.i, sizeof m.i, "(i64.const 0)");
    snprintf(m.f, sizeof m.f, "(f64.const 0)");
    snprintf(m.b, sizeof m.b, "(ref.null any)");
    return m;
}
MCell mcell_imm_int(int64_t v) {
    MCell m = mcell_imm(TAG_INT);
    snprintf(m.i, sizeof m.i, "(i64.const %lld)", (long long)v);
    return m;
}
MCell mcell_imm_float(double v) {
    MCell m = mcell_imm(TAG_FLOAT);
    snprintf(m.f, sizeof m.f, "(f64.const %.17g)", v);
    return m;
}
/* A provably int or float local, read in place. */
MCell mcell_typed_local(int slot, int is_float) {
    MCell m = mcell_imm(is_float ? TAG_FLOAT : TAG_INT);
    snprintf(is_float ? m.f : m.i, sizeof m.i, "(local.get $L%d)", slot);
    return m;
}

/* --- emission --- */

int mt_alloc(CG *c, int n) {
    int k = c->mt_depth;
    c->mt_depth += n;
    if (c->mt_depth > c->mt_max) cg_error(c, "internal: maybe-typed temporaries exceed the pre-pass bound");
    return k;
}
void emit_set_tag(CG *c, const MCell *m, int tag, int depth) {
    emit_linef(c, depth, "(local.set %s (i32.const %d))\n", m->st, tag);
}
/* `(call $box_num tag i f b)` — the cell as a Lua value. */
static void emit_maybe_cell_box(CG *c, const MCell *m, int depth) {
    emit_linef(c, depth, "(call $box_num %s %s %s %s)\n", m->t, m->i, m->f, m->b);
}
void emit_maybe_slot_box(CG *c, int slot, int depth) {
    MCell m = mcell_slot(slot);
    emit_maybe_cell_box(c, &m, depth);
}
/* The f64 view of a cell known to be numeric (tag 1 or 2). */
static void emit_cell_f64(CG *c, const MCell *m, int depth) {
    emit_linef(c, depth, "(if (result f64) (i32.eq %s (i32.const 2)) (then %s) (else (f64.convert_i64_s %s)))\n",
               m->t, m->f, m->i);
}
static void emit_both_tags(CG *c, const MCell *a, const MCell *b, int tag, int depth) {
    emit_linef(c, depth, "(i32.and (i32.eq %s (i32.const %d)) (i32.eq %s (i32.const %d)))\n", a->t, tag, b->t, tag);
}
/* d = generic helper(box a, box b); tag 0. */
static void emit_maybe_generic2(CG *c, const char *helper, const MCell *a, const MCell *b,
                                const MCell *d, int depth) {
    emit_linef(c, depth, "(local.set %s (call %s\n", d->sb, helper);
    emit_maybe_cell_box(c, a, depth + 1);
    emit_maybe_cell_box(c, b, depth + 1);
    emit_line(c, depth, "))\n");
    emit_set_tag(c, d, TAG_BOXED, depth);
}

/* Evaluate the two operands of a lowered binop left to right into cells:
 * immediates in place, anything else into a fresh temporary. Returns the
 * temporary depth to restore once the result has been computed. */
static int emit_maybe_operands(CG *c, const Expr *l, const Expr *r, MCell *a, MCell *b, int depth) {
    int k = c->mt_depth;
    int il = operand_immediate(c, l, r, a), ir = operand_immediate(c, r, NULL, b);
    int next = k;
    if (!il) *a = mcell_tmp(next++);
    if (!ir) *b = mcell_tmp(next++);
    mt_alloc(c, next - k);
    if (!il) emit_maybe_lower(c, l, a, depth);
    if (!ir) emit_maybe_lower(c, r, b, depth);
    return k;
}

/* d = a <op> b over two cells: int×int inline (i64; `/` converts to f64;
 * `//` `%` via the floor helpers), numeric with a float side inline for
 * + - * /, everything else through the generic helper. */
static void emit_maybe_arith(CG *c, BinOp op, const MCell *a, const MCell *b, const MCell *d, int depth) {
    const char *iop = NULL, *ifn = NULL, *fop = NULL;
    switch (op) {
    case BIN_ADD: iop = "i64.add", fop = "f64.add"; break;
    case BIN_SUB: iop = "i64.sub", fop = "f64.sub"; break;
    case BIN_MUL: iop = "i64.mul", fop = "f64.mul"; break;
    case BIN_DIV: fop = "f64.div"; break;
    case BIN_FDIV: ifn = "$idiv_floor"; break;
    case BIN_MOD: ifn = "$imod_floor"; break;
    default: cg_error(c, "internal: emit_maybe_arith on a non-arithmetic op"); return;
    }
    emit_line(c, depth, "(if\n");
    emit_both_tags(c, a, b, TAG_INT, depth + 1);
    emit_line(c, depth + 1, "(then\n");
    emit_indent(c, depth + 2);
    if (op == BIN_DIV) {
        wat_appendf(c->w, "(local.set %s (f64.div (f64.convert_i64_s %s) (f64.convert_i64_s %s)))\n", d->sf, a->i, b->i);
        emit_set_tag(c, d, TAG_FLOAT, depth + 2);
    } else if (ifn) {
        wat_appendf(c->w, "(local.set %s (call %s %s %s))\n", d->si, ifn, a->i, b->i);
        emit_set_tag(c, d, TAG_INT, depth + 2);
    } else {
        wat_appendf(c->w, "(local.set %s (%s %s %s))\n", d->si, iop, a->i, b->i);
        emit_set_tag(c, d, TAG_INT, depth + 2);
    }
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth + 1, "(else\n");
    if (fop) {
        emit_linef(c, depth + 2, "(if (i32.and (i32.ne %s (i32.const 0)) (i32.ne %s (i32.const 0)))\n", a->t, b->t);
        emit_line(c, depth + 3, "(then\n");
        emit_linef(c, depth + 4, "(local.set %s (%s\n", d->sf, fop);
        emit_cell_f64(c, a, depth + 5);
        emit_cell_f64(c, b, depth + 5);
        emit_line(c, depth + 4, "))\n");
        emit_set_tag(c, d, TAG_FLOAT, depth + 4);
        emit_line(c, depth + 3, ")\n");
        emit_line(c, depth + 3, "(else\n");
        emit_maybe_generic2(c, binop_helper(op), a, b, d, depth + 4);
        emit_line(c, depth + 3, "))\n");
    } else {
        emit_maybe_generic2(c, binop_helper(op), a, b, d, depth + 2);
    }
    emit_line(c, depth + 1, "))\n");
}

static void emit_maybe_neg(CG *c, const MCell *a, const MCell *d, int depth) {
    emit_linef(c, depth, "(if (i32.eq %s (i32.const 1))\n", a->t);
    emit_linef(c, depth + 1, "(then (local.set %s (i64.sub (i64.const 0) %s))\n", d->si, a->i);
    emit_set_tag(c, d, TAG_INT, depth + 2);
    emit_linef(c, depth + 1, ")\n");
    emit_linef(c, depth + 1, "(else (if (i32.eq %s (i32.const 2))\n", a->t);
    emit_linef(c, depth + 2, "(then (local.set %s (f64.neg %s))\n", d->sf, a->f);
    emit_set_tag(c, d, TAG_FLOAT, depth + 3);
    emit_line(c, depth + 2, ")\n");
    emit_line(c, depth + 2, "(else\n");
    emit_linef(c, depth + 3, "(local.set %s (call $lua_neg\n", d->sb);
    emit_maybe_cell_box(c, a, depth + 4);
    emit_line(c, depth + 3, "))\n");
    emit_set_tag(c, d, TAG_BOXED, depth + 3);
    emit_line(c, depth + 2, "))))\n");
}

/* --- inline math builtins ---
 * `sqrt(x)` / `math.floor(x)` and friends in a lowered tree: the callee is
 * evaluated as usual, then a runtime identity check against the builtin's
 * closure global guards an inline f64.sqrt / abs / floor / ceil on a numeric
 * argument; any other callee or argument takes the ordinary call. The
 * decision of WHERE to emit the guard comes from the callee expression
 * (`math.<key>`) or, for a local / upvalue, from its declaration's
 * initializer — a heuristic only, the guard carries the correctness. */
static const struct {
    const char *key;
    MathBuiltin kind;
} MATH_INLINE[] = {{"sqrt", MB_SQRT}, {"abs", MB_ABS}, {"floor", MB_FLOOR}, {"ceil", MB_CEIL}};

static MathBuiltin math_index_kind(CG *c, const Expr *e) {
    if (e->kind != EXPR_INDEX) return MB_NONE;
    const Expr *t = e->as.index.table, *k = e->as.index.key;
    if (t->kind != EXPR_VAR || t->as.var.kind != VAR_GLOBAL) return MB_NONE;
    if (c->pr->globals.items[t->as.var.idx].name_len != 4 ||
        memcmp(c->pr->globals.items[t->as.var.idx].name, "math", 4) != 0)
        return MB_NONE;
    if (k->kind != EXPR_STRING) return MB_NONE;
    for (size_t i = 0; i < sizeof(MATH_INLINE) / sizeof(MATH_INLINE[0]); i++)
        if (strlen(MATH_INLINE[i].key) == k->as.s.len && memcmp(MATH_INLINE[i].key, k->as.s.bytes, k->as.s.len) == 0)
            return MATH_INLINE[i].kind;
    return MB_NONE;
}

/* The initializer of the `local` statement declaring `slot` in `b`, if it
 * is a single-valued position; NULL otherwise. */
typedef struct {
    int slot, found;
    const Expr *init;
} LocalInit;
static void find_local_init_visit(const Stmt *s, void *ctx) {
    LocalInit *li = ctx;
    if (li->found || s->kind != STMT_LOCAL) return;
    int nn = s->as.local.n_names, nv = s->as.local.n_values;
    int last_call = nv > 0 && is_multival_tail(s->as.local.values[nv - 1]);
    int n_lead = last_call ? nv - 1 : nv;
    for (int j = 0; j < nn; j++)
        if (s->as.local.local_idxs[j] == li->slot) {
            li->found = 1;
            li->init = j < n_lead ? s->as.local.values[j] : NULL;
            return;
        }
}
static const Expr *find_local_init_block(const Block *b, int slot) {
    LocalInit li = {.slot = slot};
    walk_stmts(b, find_local_init_visit, &li);
    return li.init;
}

MathBuiltin callee_math_kind(CG *c, const Expr *callee) {
    MathBuiltin k = math_index_kind(c, callee);
    if (k || callee->kind != EXPR_VAR) return k;
    const Block *body;
    int slot;
    if (callee->as.var.kind == VAR_LOCAL) {
        body = c->cur_func_idx < 0 ? &c->pr->main_body : &c->pr->funcs.items[c->cur_func_idx]->body;
        slot = callee->as.var.idx;
    } else if (callee->as.var.kind == VAR_UPVAL && c->cur_func_idx >= 0) {
        int of, os;
        resolve_upval_origin(c, c->cur_func_idx, callee->as.var.idx, &of, &os);
        if (of == -2) return MB_NONE;
        body = of < 0 ? &c->pr->main_body : &c->pr->funcs.items[of]->body;
        slot = os;
    } else {
        return MB_NONE;
    }
    const Expr *init = find_local_init_block(body, slot);
    return init ? math_index_kind(c, init) : MB_NONE;
}

/* The wasm global holding the builtin closure for math.<key>. */
static const char *math_builtin_global(MathBuiltin k) {
    const char *key = MATH_INLINE[k - 1].key;
    int nb = builtin_count();
    for (int i = 0; i < nb; i++)
        if (builtin_class(i) == BLT_LIB_MATH && strcmp(builtin_lib_key(i), key) == 0) return builtin_func_name(i) + 1;
    return NULL;
}

/* d = <math builtin>(arg) with the guarded inline fast path. */
static void emit_maybe_math_call(CG *c, const Expr *e, MathBuiltin mk, const MCell *d, int depth) {
    const char *glob = math_builtin_global(mk);
    if (!glob) {
        cg_error(c, "internal: math builtin global not found");
        return;
    }
    int k = c->mt_depth;
    MCell cv = mcell_tmp(k); /* the callee, never the destination (d may be the arg) */
    mt_alloc(c, 1);
    emit_linef(c, depth, "(local.set %s\n", cv.sb);
    emit_expr(c, e->as.call.callee, depth + 1);
    emit_line(c, depth, ")\n");
    MCell a;
    if (!operand_immediate(c, e->as.call.args[0], NULL, &a)) {
        a = mcell_tmp(k + 1);
        mt_alloc(c, 1);
        emit_maybe_lower(c, e->as.call.args[0], &a, depth);
    }
    emit_linef(c, depth, "(if (i32.and (ref.eq (ref.cast (ref null eq) %s) (global.get $g_%s)) (i32.ne %s (i32.const 0)))\n",
               cv.b, glob, a.t);
    emit_line(c, depth + 1, "(then\n");
    switch (mk) {
    case MB_SQRT:
        emit_linef(c, depth + 2, "(local.set %s (f64.sqrt\n", d->sf);
        emit_cell_f64(c, &a, depth + 3);
        emit_line(c, depth + 2, "))\n");
        emit_set_tag(c, d, TAG_FLOAT, depth + 2);
        break;
    case MB_ABS:
        emit_linef(c, depth + 2, "(if (i32.eq %s (i32.const 1))\n", a.t);
        emit_linef(c, depth + 3, "(then (local.set %s (select (i64.sub (i64.const 0) %s) %s (i64.lt_s %s (i64.const 0))))\n",
                   d->si, a.i, a.i, a.i);
        emit_set_tag(c, d, TAG_INT, depth + 4);
        emit_line(c, depth + 3, ")\n");
        emit_linef(c, depth + 3, "(else (local.set %s (f64.abs %s))\n", d->sf, a.f);
        emit_set_tag(c, d, TAG_FLOAT, depth + 4);
        emit_line(c, depth + 3, "))\n");
        break;
    case MB_FLOOR:
    case MB_CEIL:
        /* An int is its own floor; a float rounds and converts to an
         * integer when it fits (reference pushnumint), else stays float. */
        emit_linef(c, depth + 2, "(if (i32.eq %s (i32.const 1))\n", a.t);
        emit_linef(c, depth + 3, "(then (local.set %s %s)\n", d->si, a.i);
        emit_set_tag(c, d, TAG_INT, depth + 4);
        emit_line(c, depth + 3, ")\n");
        emit_linef(c, depth + 3, "(else (local.set %s (%s %s))\n", d->sf, mk == MB_FLOOR ? "f64.floor" : "f64.ceil", a.f);
        emit_linef(c, depth + 4, "(if (i32.and (f64.ge %s (f64.const -9223372036854775808)) (f64.lt %s (f64.const 9223372036854775808)))\n",
                   d->f, d->f);
        emit_linef(c, depth + 5, "(then (local.set %s (i64.trunc_f64_s %s))\n", d->si, d->f);
        emit_set_tag(c, d, TAG_INT, depth + 6);
        emit_line(c, depth + 5, ")\n");
        emit_line(c, depth + 5, "(else\n");
        emit_set_tag(c, d, TAG_FLOAT, depth + 6);
        emit_line(c, depth + 5, "))\n");
        emit_line(c, depth + 3, "))\n");
        break;
    default: break;
    }
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth + 1, "(else\n");
    emit_linef(c, depth + 2, "(local.set %s (call $args_first (call $lua_call_any %s (array.new_fixed $ArgArr 1\n", d->sb, cv.b);
    emit_maybe_cell_box(c, &a, depth + 3);
    emit_linef(c, depth + 2, ") (i32.const %d))))\n", e->line);
    emit_linef(c, depth + 2, "(call $unbox_num %s)\n", d->b);
    emit_linef(c, depth + 2, "local.set %s\n", d->sf);
    emit_linef(c, depth + 2, "local.set %s\n", d->si);
    emit_linef(c, depth + 2, "local.set %s\n", d->st);
    emit_line(c, depth + 1, "))\n");
    c->mt_depth = k;
}

/* Lower `e` into cell `d` as a statement sequence. Provably typed
 * subexpressions keep their unboxed paths; a maybe read is a cell copy;
 * arithmetic and unary minus recurse; anything else is evaluated as a Lua
 * value and classified once. */
void emit_maybe_lower(CG *c, const Expr *e, const MCell *d, int depth) {
    if (!c->ok) return;
    if (expr_is_int(c, e)) {
        emit_linef(c, depth, "(local.set %s\n", d->si);
        emit_int_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        emit_set_tag(c, d, TAG_INT, depth);
        return;
    }
    if (expr_is_float(c, e)) {
        emit_linef(c, depth, "(local.set %s\n", d->sf);
        emit_float_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        emit_set_tag(c, d, TAG_FLOAT, depth);
        return;
    }
    switch (e->kind) {
    case EXPR_VAR:
        if (e->as.var.kind == VAR_LOCAL && slot_is_maybe(c, e->as.var.idx)) {
            MCell src = mcell_slot(e->as.var.idx);
            if (strcmp(src.st, d->st) == 0) return; /* x = x */
            emit_linef(c, depth, "(local.set %s %s)\n", d->st, src.t);
            emit_linef(c, depth, "(local.set %s %s)\n", d->si, src.i);
            emit_linef(c, depth, "(local.set %s %s)\n", d->sf, src.f);
            emit_linef(c, depth, "(local.set %s %s)\n", d->sb, src.b);
            return;
        }
        break;
    case EXPR_BINOP:
        if (maybe_arith_op(e->as.binop.op)) {
            MCell a, b;
            int k = emit_maybe_operands(c, e->as.binop.lhs, e->as.binop.rhs, &a, &b, depth);
            emit_maybe_arith(c, e->as.binop.op, &a, &b, d, depth);
            c->mt_depth = k;
            return;
        }
        break;
    case EXPR_CALL: {
        MathBuiltin mk;
        if (e->as.call.nargs == 1 && !is_multival_tail(e->as.call.args[0]) &&
            (mk = callee_math_kind(c, e->as.call.callee)) != MB_NONE) {
            emit_maybe_math_call(c, e, mk, d, depth);
            return;
        }
        break;
    }
    case EXPR_INDEX: {
        /* A table read straight into the cell: an unboxed float slot arrives
         * as tag 2 with no allocation, anything else classified once. */
        const Expr *key = e->as.index.key;
        int kstr = key->kind == EXPR_STRING && key->as.s.len <= KSTR_MAX;
        int kint = !kstr && expr_is_int(c, key);
        int kmaybe = !kstr && !kint && key->kind == EXPR_VAR && key->as.var.kind == VAR_LOCAL &&
                     slot_is_maybe(c, key->as.var.idx);
        if (kint || kmaybe) { /* the array part probed inline (arrays.c) */
            MCell kc = kmaybe ? mcell_slot(key->as.var.idx) : (MCell){0};
            emit_expr(c, e->as.index.table, depth);
            if (kint) emit_int_expr(c, key, depth);
            emit_ix_get_cell(c, kmaybe ? &kc : NULL, d, e->line, depth);
            return;
        }
        if (kstr) {
            char icb[48];
            const char *ic = ic_new(c, icb, sizeof icb);
            emit_line(c, depth, ic ? "(call $lua_index_ic_cell\n" : "(call $lua_index_sk_cell\n");
            emit_expr(c, e->as.index.table, depth + 1);
            emit_string_literal(c, key->as.s.bytes, key->as.s.len, depth + 1);
            emit_linef(c, depth + 1, "(i32.const %d)%s%s\n", e->line, ic ? " " : "", ic ? ic : "");
            emit_line(c, depth, ")\n");
            emit_linef(c, depth, "local.set %s\n", d->sb);
            emit_linef(c, depth, "local.set %s\n", d->sf);
            emit_linef(c, depth, "local.set %s\n", d->si);
            emit_linef(c, depth, "local.set %s\n", d->st);
            return;
        }
        break;
    }
    case EXPR_UNOP:
        if (e->as.unop.op == UN_NEG) {
            int k = c->mt_depth;
            MCell a;
            if (!operand_immediate(c, e->as.unop.operand, NULL, &a)) {
                mt_alloc(c, 1);
                a = mcell_tmp(k);
                emit_maybe_lower(c, e->as.unop.operand, &a, depth);
            }
            emit_maybe_neg(c, &a, d, depth);
            c->mt_depth = k;
            return;
        }
        break;
    default: break;
    }
    /* Opaque: a Lua value, classified once. */
    emit_linef(c, depth, "(local.set %s\n", d->sb);
    emit_expr(c, e, depth + 1);
    emit_line(c, depth, ")\n");
    emit_linef(c, depth, "(call $unbox_num %s)\n", d->b);
    emit_linef(c, depth, "local.set %s\n", d->sf);
    emit_linef(c, depth, "local.set %s\n", d->si);
    emit_linef(c, depth, "local.set %s\n", d->st);
}

/* `slot = e` for a maybe slot. */
void emit_maybe_store(CG *c, int slot, const Expr *e, int depth) {
    MCell d = mcell_slot(slot);
    emit_maybe_lower(c, e, &d, depth);
}

/* A lowered arithmetic tree in a Lua-value context:
 *   (block (result anyref) <lower into a temporary> (call $box_num …)) */
void emit_maybe_boxed(CG *c, const Expr *e, int depth) {
    int k = mt_alloc(c, 1);
    MCell d = mcell_tmp(k);
    emit_line(c, depth, "(block (result anyref)\n");
    emit_maybe_lower(c, e, &d, depth + 1);
    emit_maybe_cell_box(c, &d, depth + 1);
    emit_line(c, depth, ")\n");
    c->mt_depth = k;
}

/* The mixed int/float compare of cells a (lhs) and b (rhs), one int and one
 * float, as an i32: an f64 compare when the int side is an exactly
 * representable literal, else the exact helper. */
static void emit_mixed_cell_cmp(CG *c, const CmpOp *op, const Expr *e, const MCell *a, const MCell *b,
                                int int_left, int depth) {
    const MCell *ic = int_left ? a : b, *fc = int_left ? b : a;
    if (expr_is_exact_f64_int_literal(int_left ? e->as.binop.lhs : e->as.binop.rhs)) {
        if (int_left) emit_linef(c, depth, "(%s (f64.convert_i64_s %s) %s)\n", op->f64, ic->i, fc->f);
        else emit_linef(c, depth, "(%s %s (f64.convert_i64_s %s))\n", op->f64, fc->f, ic->i);
    } else {
        emit_linef(c, depth, "%s(call %s %s %s)%s\n", op->negate ? "(i32.eqz " : "",
                   int_left ? op->int_float : op->float_int, int_left ? ic->i : fc->f, int_left ? fc->f : ic->i,
                   op->negate ? ")" : "");
    }
}

/* A comparison involving an opaque operand, as `(block (result i32) …)`:
 * same-tag int or float compares inline, mixed int/float through the exact
 * mixed compare, and everything else through the generic helper +
 * $lua_truthy. */
void emit_maybe_cmp_block(CG *c, const Expr *e, int depth) {
    const CmpOp *op = cmp_op(e->as.binop.op);
    MCell a, b;
    emit_line(c, depth, "(block (result i32)\n");
    int k = emit_maybe_operands(c, e->as.binop.lhs, e->as.binop.rhs, &a, &b, depth + 1);
    emit_line(c, depth + 1, "(if (result i32)\n");
    emit_both_tags(c, &a, &b, TAG_INT, depth + 2);
    emit_linef(c, depth + 2, "(then (%s %s %s))\n", op->i64, a.i, b.i);
    emit_line(c, depth + 2, "(else (if (result i32)\n");
    emit_both_tags(c, &a, &b, TAG_FLOAT, depth + 3);
    emit_linef(c, depth + 3, "(then (%s %s %s))\n", op->f64, a.f, b.f);
    /* Both numeric with different tags: int vs float. A side whose tag is
     * static decides which way round; otherwise test at run time. */
    int at = a.static_tag, bt = b.static_tag;
    int mixed = !(at && bt && at == bt);
    if (mixed) {
        emit_linef(c, depth + 3, "(else (if (result i32) (i32.and (i32.ne %s (i32.const 0)) (i32.ne %s (i32.const 0)))\n",
                   a.t, b.t);
        emit_line(c, depth + 4, "(then\n");
        if (at == TAG_INT || bt == TAG_FLOAT) {
            emit_mixed_cell_cmp(c, op, e, &a, &b, 1, depth + 5);
        } else if (at == TAG_FLOAT || bt == TAG_INT) {
            emit_mixed_cell_cmp(c, op, e, &a, &b, 0, depth + 5);
        } else {
            emit_linef(c, depth + 5, "(if (result i32) (i32.eq %s (i32.const 1))\n", a.t);
            emit_line(c, depth + 6, "(then\n");
            emit_mixed_cell_cmp(c, op, e, &a, &b, 1, depth + 7);
            emit_line(c, depth + 6, ")\n");
            emit_line(c, depth + 6, "(else\n");
            emit_mixed_cell_cmp(c, op, e, &a, &b, 0, depth + 7);
            emit_line(c, depth + 6, "))\n");
        }
        emit_line(c, depth + 4, ")\n");
    }
    emit_linef(c, depth + 3 + mixed, "(else (call $lua_truthy (call %s\n", binop_helper(e->as.binop.op));
    emit_maybe_cell_box(c, &a, depth + 4 + mixed);
    emit_maybe_cell_box(c, &b, depth + 4 + mixed);
    emit_line(c, depth + 3 + mixed, mixed ? "))))))))\n" /* call, call, else, if(mixed), else, if, else, if */
                                          : "))))))\n"); /* call, call, else, if, else, if */
    emit_line(c, depth, ")\n");
    c->mt_depth = k;
}
