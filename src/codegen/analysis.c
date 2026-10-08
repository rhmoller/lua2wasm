/* What codegen works out about a function body before emitting it: the
 * statement traversal, the int / float / maybe-typed slot analyses, how many
 * lowering temporaries it needs, the function-binding maps behind direct
 * calls, and whole-program signature inference. */
#include "internal.h"

/* ----- statement traversal -----
 * Analyses look at one function body at a time: every statement, those in
 * nested blocks included, but not nested function literals — each function
 * is analysed on its own. */

/* Call fn on each block nested directly in s, in source order: an `if`'s arm
 * bodies then its else body, or the body of a loop or `do`. */
void for_each_nested_block(const Stmt *s, BlockVisit fn, void *ctx) {
    switch (s->kind) {
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++) fn(&s->as.if_stmt.arms[a].body, ctx);
        if (s->as.if_stmt.has_else) fn(&s->as.if_stmt.else_body, ctx);
        break;
    case STMT_WHILE: fn(&s->as.while_stmt.body, ctx); break;
    case STMT_DO: fn(&s->as.do_stmt.body, ctx); break;
    case STMT_REPEAT: fn(&s->as.repeat.body, ctx); break;
    case STMT_FOR_NUM: fn(&s->as.for_num.body, ctx); break;
    case STMT_FOR_GEN: fn(&s->as.for_gen.body, ctx); break;
    default: break;
    }
}

typedef struct {
    StmtVisit fn;
    void *ctx;
} StmtWalk;
static void walk_stmts_in(const Block *b, void *walk) {
    const StmtWalk *w = walk;
    for (size_t i = 0; i < b->count; i++) {
        w->fn(b->items[i], w->ctx);
        for_each_nested_block(b->items[i], walk_stmts_in, walk);
    }
}

/* Call fn on every statement of b, nested ones included, in source order:
 * each statement before those nested in it. */
void walk_stmts(const Block *b, StmtVisit fn, void *ctx) {
    StmtWalk w = {fn, ctx};
    walk_stmts_in(b, &w);
}

/* Call fn on each expression s evaluates itself — not those of its nested
 * blocks: values, conditions, index targets, loop bounds, iterators. */
void for_each_own_expr(const Stmt *s, ExprVisit fn, void *ctx) {
    switch (s->kind) {
    case STMT_LOCAL:
        for (int i = 0; i < s->as.local.n_values; i++) fn(s->as.local.values[i], ctx);
        break;
    case STMT_ASSIGN:
        for (int i = 0; i < s->as.assign.n_targets; i++)
            if (s->as.assign.targets[i].kind == TGT_INDEX) {
                fn(s->as.assign.targets[i].as.index.table, ctx);
                fn(s->as.assign.targets[i].as.index.key, ctx);
            }
        for (int i = 0; i < s->as.assign.n_values; i++) fn(s->as.assign.values[i], ctx);
        break;
    case STMT_EXPR: fn(s->as.expr_stmt.expr, ctx); break;
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++) fn(s->as.if_stmt.arms[a].cond, ctx);
        break;
    case STMT_WHILE: fn(s->as.while_stmt.cond, ctx); break;
    case STMT_REPEAT: fn(s->as.repeat.cond, ctx); break;
    case STMT_RETURN:
        for (int i = 0; i < s->as.return_stmt.n_values; i++) fn(s->as.return_stmt.values[i], ctx);
        break;
    case STMT_FOR_NUM:
        fn(s->as.for_num.start, ctx);
        fn(s->as.for_num.stop, ctx);
        if (s->as.for_num.step) fn(s->as.for_num.step, ctx);
        break;
    case STMT_FOR_GEN:
        for (int i = 0; i < s->as.for_gen.n_exprs; i++) fn(s->as.for_gen.exprs[i], ctx);
        break;
    case STMT_GLOBAL:
        for (int i = 0; i < s->as.global_decl.n_values; i++) fn(s->as.global_decl.values[i], ctx);
        break;
    default: break;
    }
}

typedef struct {
    ExprVisit fn;
    void *ctx;
} ExprWalk;
static void walk_own_exprs(const Stmt *s, void *walk) {
    const ExprWalk *w = walk;
    for_each_own_expr(s, w->fn, w->ctx);
}

/* Call fn on every expression the statements of b evaluate, nested blocks
 * included. fn sees the roots; it recurses into sub-expressions itself. */
static void walk_block_exprs(const Block *b, ExprVisit fn, void *ctx) {
    ExprWalk w = {fn, ctx};
    walk_stmts(b, walk_own_exprs, &w);
}

/* ----- integer specialization (opt >= 1) ----- */

/* Is this slot a local proven to hold only integers (declared as i64)? */
int slot_is_int(const CG *c, int slot) {
    if (!c->opt_int || !c->cur_is_int) return 0;
    if (slot < 0 || slot >= c->cur_n_locals) return 0;
    return c->cur_is_int[slot];
}

/* True iff `e` provably evaluates to a Lua integer and can be emitted as a
 * raw i64 via emit_int_expr. Conservative: only integer literals, i64 locals,
 * and integer-closed arithmetic over those. `/` and `^` are always float; `<<`
 * `>>` have non-trivial Lua semantics so are left to the generic path. */
int expr_is_int(CG *c, const Expr *e) {
    if (!c->opt_int) return 0;
    switch (e->kind) {
    case EXPR_INT: return 1;
    case EXPR_VAR:
        return e->as.var.kind == VAR_LOCAL && slot_is_int(c, e->as.var.idx);
    case EXPR_BINOP:
        switch (e->as.binop.op) {
        case BIN_ADD:
        case BIN_SUB:
        case BIN_MUL:
        case BIN_FDIV:
        case BIN_MOD:
        case BIN_BAND:
        case BIN_BOR:
        case BIN_BXOR:
            return expr_is_int(c, e->as.binop.lhs) && expr_is_int(c, e->as.binop.rhs);
        default: return 0;
        }
    case EXPR_UNOP:
        return (e->as.unop.op == UN_NEG || e->as.unop.op == UN_BNOT) && expr_is_int(c, e->as.unop.operand);
    case EXPR_CALL: {
        /* A direct call to an int-returning function, callable with typed args
         * from here, yields a raw i64 (its $user_N_da1 returns i64). */
        const LuaFunc *K = direct_call_target(c, e);
        const FuncSig *sg = target_sig(c, K);
        return sg && sg->ret_ty == NT_INT && direct_args_typed_ok(c, e, K);
    }
    default: return 0;
    }
}

/* Is this slot a local proven to hold only floats (declared as f64)? */
int slot_is_float(const CG *c, int slot) {
    if (!c->opt_int || !c->cur_is_float) return 0;
    if (slot < 0 || slot >= c->cur_n_locals) return 0;
    return c->cur_is_float[slot];
}

/* True iff `e` provably evaluates to a Lua float and can be emitted as a raw
 * f64 via emit_float_expr. `/` is always float; `+ - *` are float when at
 * least one operand is float and the other is numeric (int promotes). `// % ^`
 * are left to the generic path for now. */
int expr_is_float(CG *c, const Expr *e) {
    if (!c->opt_int) return 0;
    switch (e->kind) {
    case EXPR_FLOAT: return 1;
    case EXPR_VAR:
        return e->as.var.kind == VAR_LOCAL && slot_is_float(c, e->as.var.idx);
    case EXPR_BINOP: {
        const Expr *l = e->as.binop.lhs, *r = e->as.binop.rhs;
        int ln = expr_is_int(c, l) || expr_is_float(c, l);
        int rn = expr_is_int(c, r) || expr_is_float(c, r);
        switch (e->as.binop.op) {
        case BIN_DIV: return ln && rn; /* always float */
        case BIN_ADD:
        case BIN_SUB:
        case BIN_MUL:
            return ln && rn && (expr_is_float(c, l) || expr_is_float(c, r));
        default: return 0;
        }
    }
    case EXPR_UNOP:
        return e->as.unop.op == UN_NEG && expr_is_float(c, e->as.unop.operand);
    case EXPR_CALL: {
        /* A direct call to a float-returning function (its $user_N_da1 returns
         * f64), callable with typed args from here. */
        const LuaFunc *K = direct_call_target(c, e);
        const FuncSig *sg = target_sig(c, K);
        return sg && sg->ret_ty == NT_FLOAT && direct_args_typed_ok(c, e, K);
    }
    default: return 0;
    }
}

/* One run of a slot-typing analysis: out[] holds the slots still believed
 * to have the type; a kill rule that finds a store contradicting it drops
 * the slot, and the analysis reruns until nothing changes. */
typedef struct {
    CG *c;
    unsigned char *out;
    int changed;
    NumTy ty; /* the int / float analysis: NT_INT or NT_FLOAT */
} SlotPass;

static void slot_kill(SlotPass *p, int slot) {
    if (slot >= 0 && slot < p->c->cur_n_locals && p->out[slot]) {
        p->out[slot] = 0;
        p->changed = 1;
    }
}

/* Lua 5.4+: integer init and step make a numeric for an integer loop,
 * whatever the limit is ($for_limit settles a non-integer limit at loop
 * entry). */
static int int_for_loop(CG *c, const Stmt *s) {
    const Expr *st = s->as.for_num.step;
    return expr_is_int(c, s->as.for_num.start) && (st == NULL || expr_is_int(c, st));
}

static int expr_has_ty(CG *c, const Expr *e, NumTy ty) {
    return ty == NT_INT ? expr_is_int(c, e) : expr_is_float(c, e);
}

/* Kill rules of the int and float analyses: a slot keeps the type only if
 * every store to it is a single expression of that type (a multi-value store
 * writes anyref). Never typed: a <close> variable, whose value flows into the
 * to-be-closed machinery ($tbc_push/$close_upto) as an anyref; generic-for
 * variables; local functions; and numeric-for control variables, except the
 * int one of an integer loop (there is no f64 for-loop). */
static void typed_kill_stmt(const Stmt *s, void *ctx) {
    SlotPass *p = ctx;
    CG *c = p->c;
    switch (s->kind) {
    case STMT_LOCAL: {
        int nn = s->as.local.n_names, nv = s->as.local.n_values;
        for (int j = 0; j < nn; j++) {
            int is_close = s->as.local.attribs && s->as.local.attribs[j] == 2;
            if (!is_close && nv == nn && expr_has_ty(c, s->as.local.values[j], p->ty)) continue;
            slot_kill(p, s->as.local.local_idxs[j]);
        }
        break;
    }
    case STMT_ASSIGN: {
        int nt = s->as.assign.n_targets, nv = s->as.assign.n_values;
        for (int j = 0; j < nt; j++) {
            const AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind != TGT_VAR || t->as.var.kind != VAR_LOCAL) continue;
            if (nt == 1 && nv == 1 && expr_has_ty(c, s->as.assign.values[0], p->ty)) continue;
            slot_kill(p, t->as.var.idx);
        }
        break;
    }
    case STMT_FOR_NUM:
        if (p->ty != NT_INT || !int_for_loop(c, s)) slot_kill(p, s->as.for_num.local_idx);
        break;
    case STMT_FOR_GEN:
        for (int j = 0; j < s->as.for_gen.n_names; j++) slot_kill(p, s->as.for_gen.local_idxs[j]);
        break;
    case STMT_LOCAL_FUNC: slot_kill(p, s->as.local_func.local_idx); break;
    default: break;
    }
}

/* Fill out[0..n_locals) with the integer-only slots of one function body.
 * Optimistic start (every non-param, non-captured slot is a candidate), then
 * fixpoint-remove any contradicted by an assignment. A non-NULL param_seed
 * (the typed direct entries $user_N_da/_da1) additionally seeds parameter slots
 * marked NT_INT, so an i64 parameter is unboxed in the body. During inference a
 * still-undetermined parameter (NT_UNSET) is *optimistically* seeded int so a
 * self-recursive call's argument (e.g. `n-1`) types as int instead of poisoning
 * the parameter to ANY before the external call sites are seen; emission only
 * ever passes finalized seeds (no NT_UNSET). */
void compute_int_slots(CG *c, const Block *body, int n_locals, int n_params,
                       const unsigned char *captured, unsigned char *out,
                       const NumTy *param_seed) {
    for (int i = 0; i < n_locals; i++) {
        if (captured && captured[i]) {
            out[i] = 0;
            continue;
        }
        out[i] = (i >= n_params) ||
                 (param_seed && (param_seed[i] == NT_INT || param_seed[i] == NT_UNSET));
    }
    const unsigned char *saved = c->cur_is_int;
    int saved_n = c->cur_n_locals;
    c->cur_is_int = out;
    c->cur_n_locals = n_locals;
    SlotPass p = {.c = c, .out = out, .changed = 1, .ty = NT_INT};
    while (p.changed) {
        p.changed = 0;
        walk_stmts(body, typed_kill_stmt, &p);
    }
    c->cur_is_int = saved;
    c->cur_n_locals = saved_n;
}

/* Fill out[] with float-only slots. Run AFTER compute_int_slots (with the
 * final int bitmap live on c->cur_is_int, since expr_is_float consults
 * expr_is_int for mixed int/float operands). */
void compute_float_slots(CG *c, const Block *body, int n_locals, int n_params,
                         const unsigned char *captured, unsigned char *out,
                         const NumTy *param_seed) {
    for (int i = 0; i < n_locals; i++) {
        if ((captured && captured[i]) || (c->cur_is_int && c->cur_is_int[i])) {
            out[i] = 0;
            continue;
        }
        out[i] = (i >= n_params) || (param_seed && param_seed[i] == NT_FLOAT);
    }
    const unsigned char *saved = c->cur_is_float;
    int saved_n = c->cur_n_locals;
    c->cur_is_float = out;
    c->cur_n_locals = n_locals;
    SlotPass p = {.c = c, .out = out, .changed = 1, .ty = NT_FLOAT};
    while (p.changed) {
        p.changed = 0;
        walk_stmts(body, typed_kill_stmt, &p);
    }
    c->cur_is_float = saved;
    c->cur_n_locals = saved_n;
}

/* ===== Maybe-typed numeric locals (docs/design/22-maybe-typed-locals.md) =====
 *
 * A local fed from opaque sources (table fields, calls, `x or 0`) can't be
 * proven int or float, but usually is one at runtime. Such a slot, when it is
 * also used in arithmetic or a comparison, is emitted as four wasm locals —
 * $Lt (tag: 0 boxed / 1 int / 2 float), $Li (i64), $Lf (f64), $L (anyref) —
 * classified once per store ($unbox_num) and consumed by a tag switch that
 * runs i64/f64 ops inline and falls back to the generic runtime helper (same
 * operands, same errors) for anything else. Boxing happens only where a real
 * Lua value is needed ($box_num). Nothing here changes what is computed, only
 * which path computes it; -O0 marks no slot maybe. */

int maybe_arith_op(BinOp op) {
    switch (op) {
    case BIN_ADD:
    case BIN_SUB:
    case BIN_MUL:
    case BIN_DIV:
    case BIN_FDIV:
    case BIN_MOD: return 1;
    default: return 0;
    }
}

int slot_is_maybe(const CG *c, int slot) {
    if (!c->opt_int || !c->cur_is_maybe) return 0;
    if (slot < 0 || slot >= c->cur_n_locals) return 0;
    return c->cur_is_maybe[slot];
}

/* Could `e` evaluate to a number? Anything not statically of another type.
 * `and`/`or` count (the `t.n or 0` idiom); concatenation, comparisons, `not`
 * and non-numeric literals/constructors don't. */
static int expr_numeric_plausible(const Expr *e) {
    switch (e->kind) {
    case EXPR_INT:
    case EXPR_FLOAT:
    case EXPR_VAR:
    case EXPR_CALL:
    case EXPR_METHOD_CALL:
    case EXPR_INDEX:
    case EXPR_VARARG: return 1;
    case EXPR_BINOP:
        switch (e->as.binop.op) {
        case BIN_CONCAT:
        case BIN_EQ:
        case BIN_NEQ:
        case BIN_LT:
        case BIN_LE:
        case BIN_GT:
        case BIN_GE: return 0;
        default: return 1;
        }
    case EXPR_UNOP: return e->as.unop.op != UN_NOT;
    default: return 0;
    }
}

/* Operand classification for the lowering decision. "Opaque": a value the
 * runtime classifies rather than the compiler proves — a maybe slot, any
 * other untyped variable, a table read or a call; recursion goes through
 * arithmetic / comparison / unary-minus nodes. "Numeric evidence": something
 * that makes a number likely — a numeric literal, a provably typed
 * expression, a maybe slot, or an arithmetic node. */
static int expr_has_opaque(CG *c, const Expr *e) {
    switch (e->kind) {
    case EXPR_VAR:
        if (e->as.var.kind == VAR_LOCAL)
            return slot_is_maybe(c, e->as.var.idx) ||
                   (!slot_is_int(c, e->as.var.idx) && !slot_is_float(c, e->as.var.idx));
        return 1;
    case EXPR_INDEX:
    case EXPR_CALL:
    case EXPR_METHOD_CALL: return 1;
    case EXPR_BINOP:
        if (!maybe_arith_op(e->as.binop.op) && !is_cmp_op(e->as.binop.op)) return 0;
        return expr_has_opaque(c, e->as.binop.lhs) || expr_has_opaque(c, e->as.binop.rhs);
    case EXPR_UNOP: return e->as.unop.op == UN_NEG && expr_has_opaque(c, e->as.unop.operand);
    default: return 0;
    }
}
static int expr_numeric_evidence(CG *c, const Expr *e) {
    switch (e->kind) {
    case EXPR_INT:
    case EXPR_FLOAT: return 1;
    case EXPR_VAR:
        return e->as.var.kind == VAR_LOCAL &&
               (slot_is_maybe(c, e->as.var.idx) || slot_is_int(c, e->as.var.idx) ||
                slot_is_float(c, e->as.var.idx));
    case EXPR_BINOP:
        if (maybe_arith_op(e->as.binop.op)) return 1;
        if (!is_cmp_op(e->as.binop.op)) return 0;
        return expr_numeric_evidence(c, e->as.binop.lhs) || expr_numeric_evidence(c, e->as.binop.rhs);
    case EXPR_UNOP: return e->as.unop.op == UN_NEG;
    case EXPR_CALL: return expr_is_int(c, e) || expr_is_float(c, e);
    default: return 0;
    }
}

/* A tree is lowered by the maybe machinery iff it is an arithmetic binop or
 * a unary minus with an opaque operand, or a comparison with an opaque
 * operand AND numeric evidence on some side (so `x == nil` or `a == b` on
 * two unknowns keep the plain generic call instead of paying to classify).
 * (A bare operand answers per expr_has_opaque; callers ask about operator
 * nodes.) */
int expr_involves_maybe(CG *c, const Expr *e) {
    if (!c->opt_int || !c->cur_is_maybe) return 0;
    if (e->kind == EXPR_BINOP && is_cmp_op(e->as.binop.op))
        return expr_has_opaque(c, e) &&
               (expr_numeric_evidence(c, e->as.binop.lhs) || expr_numeric_evidence(c, e->as.binop.rhs));
    return expr_has_opaque(c, e);
}

/* --- numeric-use analysis: which slots are read inside an arithmetic,
 * comparison or unary-minus tree (through such nodes only) [use], or directly
 * as the key of a table read [key] — an integer key then reaches the array
 * part unboxed through $lua_index_mk / $lua_tabset_mk, and a non-number one
 * just stays boxed --- */
typedef struct {
    unsigned char *use;
    unsigned char *key;
    int n;
} NumUse;
static void numuse_expr(const Expr *e, NumUse *u, int in_arith);
static void numuse_child(const Expr *e, NumUse *u) { numuse_expr(e, u, 0); }
static void numuse_expr(const Expr *e, NumUse *u, int in_arith) {
    if (!e) return;
    switch (e->kind) {
    case EXPR_VAR:
        if (in_arith && e->as.var.kind == VAR_LOCAL && e->as.var.idx >= 0 && e->as.var.idx < u->n)
            u->use[e->as.var.idx] = 1;
        return;
    case EXPR_BINOP:
        if (maybe_arith_op(e->as.binop.op) || is_cmp_op(e->as.binop.op)) {
            numuse_expr(e->as.binop.lhs, u, 1);
            numuse_expr(e->as.binop.rhs, u, 1);
        } else {
            numuse_child(e->as.binop.lhs, u);
            numuse_child(e->as.binop.rhs, u);
        }
        return;
    case EXPR_UNOP: numuse_expr(e->as.unop.operand, u, e->as.unop.op == UN_NEG); return;
    case EXPR_CALL:
        numuse_child(e->as.call.callee, u);
        for (size_t i = 0; i < e->as.call.nargs; i++) numuse_child(e->as.call.args[i], u);
        return;
    case EXPR_METHOD_CALL:
        numuse_child(e->as.method_call.recv, u);
        for (size_t i = 0; i < e->as.method_call.nargs; i++) numuse_child(e->as.method_call.args[i], u);
        return;
    case EXPR_INDEX:
        numuse_child(e->as.index.table, u);
        if (e->as.index.key->kind == EXPR_VAR && e->as.index.key->as.var.kind == VAR_LOCAL &&
            e->as.index.key->as.var.idx >= 0 && e->as.index.key->as.var.idx < u->n)
            u->key[e->as.index.key->as.var.idx] = 1;
        else numuse_child(e->as.index.key, u);
        return;
    case EXPR_TABLE:
        for (int i = 0; i < e->as.table_ctor.n_entries; i++) {
            if (e->as.table_ctor.entries[i].key) numuse_child(e->as.table_ctor.entries[i].key, u);
            numuse_child(e->as.table_ctor.entries[i].value, u);
        }
        return;
    default: return;
    }
}
static void numuse_visit(const Expr *e, void *ctx) { numuse_expr(e, (NumUse *)ctx, 0); }

/* An expression whose evaluation has no side effects and reads no mutable
 * state that another operand's evaluation could change: literals, and
 * arithmetic / unary minus over literals and local variables. Used to decide
 * whether a left operand read in place must instead be copied before the
 * right operand runs. */
static int expr_side_effect_free(const Expr *e) {
    switch (e->kind) {
    case EXPR_INT:
    case EXPR_FLOAT:
    case EXPR_NIL:
    case EXPR_TRUE:
    case EXPR_FALSE:
    case EXPR_STRING: return 1;
    case EXPR_VAR: return e->as.var.kind == VAR_LOCAL;
    case EXPR_BINOP:
        return (maybe_arith_op(e->as.binop.op) || is_cmp_op(e->as.binop.op)) &&
               expr_side_effect_free(e->as.binop.lhs) && expr_side_effect_free(e->as.binop.rhs);
    case EXPR_UNOP: return e->as.unop.op == UN_NEG && expr_side_effect_free(e->as.unop.operand);
    default: return 0;
    }
}

/* If `e` can be an operand without a temporary — a numeric literal, a typed
 * local, or a maybe slot read in place — fill `out` and return 1. A variable
 * read is only used in place when the operand evaluated after it
 * (`other_after`, NULL if none) cannot modify it. */
int operand_immediate(CG *c, const Expr *e, const Expr *other_after, MCell *out) {
    switch (e->kind) {
    case EXPR_INT:
        if (out) *out = mcell_imm_int(e->as.i_val);
        return 1;
    case EXPR_FLOAT:
        if (out) *out = mcell_imm_float(e->as.f_val);
        return 1;
    case EXPR_VAR:
        if (e->as.var.kind != VAR_LOCAL) return 0;
        if (other_after && !expr_side_effect_free(other_after)) return 0;
        if (slot_is_int(c, e->as.var.idx)) {
            if (out) *out = mcell_typed_local(e->as.var.idx, 0);
            return 1;
        }
        if (slot_is_float(c, e->as.var.idx)) {
            if (out) *out = mcell_typed_local(e->as.var.idx, 1);
            return 1;
        }
        if (slot_is_maybe(c, e->as.var.idx)) {
            if (out) *out = mcell_slot(e->as.var.idx);
            return 1;
        }
        return 0;
    default: return 0;
    }
}

/* --- lowering temporaries: an upper bound on how many a body needs.
 * Lowering a binop takes a temporary per non-immediate operand above the
 * current depth and lowers each such operand above those; a unary minus
 * likewise; an opaque node's child lowered in a boxed context takes one for
 * its root. --- */
static int expr_temp_need(CG *c, const Expr *e) {
    if (!e) return 0;
    int m = 0, v;
    switch (e->kind) {
    case EXPR_BINOP: {
        const Expr *l = e->as.binop.lhs, *r = e->as.binop.rhs;
        int tl = !operand_immediate(c, l, r, NULL), tr = !operand_immediate(c, r, NULL, NULL);
        int nl = tl ? expr_temp_need(c, l) : 0, nr = tr ? expr_temp_need(c, r) : 0;
        return tl + tr + (nl > nr ? nl : nr);
    }
    case EXPR_UNOP: {
        const Expr *o = e->as.unop.operand;
        int t = !operand_immediate(c, o, NULL, NULL);
        return t + (t ? expr_temp_need(c, o) : 0);
    }
    case EXPR_CALL:
        m = 1 + expr_temp_need(c, e->as.call.callee);
        for (size_t i = 0; i < e->as.call.nargs; i++)
            if ((v = 2 + expr_temp_need(c, e->as.call.args[i])) > m) m = v; /* +1 callee cell for inline math */
        return m;
    case EXPR_METHOD_CALL:
        m = 1 + expr_temp_need(c, e->as.method_call.recv);
        for (size_t i = 0; i < e->as.method_call.nargs; i++)
            if ((v = 1 + expr_temp_need(c, e->as.method_call.args[i])) > m) m = v;
        return m;
    case EXPR_INDEX:
        m = 1 + expr_temp_need(c, e->as.index.table);
        if ((v = 1 + expr_temp_need(c, e->as.index.key)) > m) m = v;
        return m;
    case EXPR_TABLE:
        for (int i = 0; i < e->as.table_ctor.n_entries; i++) {
            if (e->as.table_ctor.entries[i].key &&
                (v = 1 + expr_temp_need(c, e->as.table_ctor.entries[i].key)) > m)
                m = v;
            if ((v = 1 + expr_temp_need(c, e->as.table_ctor.entries[i].value)) > m) m = v;
        }
        return m;
    default: return 0;
    }
}
typedef struct {
    CG *c;
    int m;
} TempNeed;
static void temp_need_visit(const Expr *e, void *ctx) {
    TempNeed *t = (TempNeed *)ctx;
    int v = 1 + expr_temp_need(t->c, e);
    if (v > t->m) t->m = v;
}
/* emit_assign_multi_cells holds a table and a key cell per index target and a
 * value cell per value while it evaluates the next sub-expression above them. */
static int multi_assign_stmt_need(CG *c, const Stmt *s) {
    int v;
    switch (s->kind) {
    case STMT_ASSIGN: {
        int nt = s->as.assign.n_targets, nv = s->as.assign.n_values;
        if (nt < 2 || nv != nt) return 0;
        int live = nv, sub = 0;
        for (int i = 0; i < nt; i++) {
            const AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind == TGT_VAR) continue;
            live += 2;
            if ((v = 1 + expr_temp_need(c, t->as.index.table)) > sub) sub = v;
            if ((v = 1 + expr_temp_need(c, t->as.index.key)) > sub) sub = v;
        }
        for (int i = 0; i < nv; i++)
            if ((v = 1 + expr_temp_need(c, s->as.assign.values[i])) > sub) sub = v;
        return live + sub;
    }
    default: return 0;
    }
}
static void multi_assign_need_visit(const Stmt *s, void *ctx) {
    TempNeed *t = ctx;
    int v = multi_assign_stmt_need(t->c, s);
    if (v > t->m) t->m = v;
}
int block_temp_need(CG *c, const Block *b) {
    TempNeed t = {.c = c, .m = 0};
    walk_block_exprs(b, temp_need_visit, &t);
    walk_stmts(b, multi_assign_need_visit, &t);
    return t.m + 2; /* + the table and value cells of an unboxed store */
}

/* A candidate used numerically only as a table key pays a classification on
 * every store, which is only worth it when the stored values are likely
 * numbers: a call result (`local k = key(x, y)`) is more often a string key,
 * so such a store disqualifies it; a table read (`local id = alive[i]`) or
 * arithmetic keeps it. */
static int key_store_ok(const CG *c, int slot, const Expr *v) {
    if (!c->maybe_key_only || slot < 0 || slot >= c->cur_n_locals || !c->maybe_key_only[slot]) return 1;
    return v->kind != EXPR_CALL && v->kind != EXPR_METHOD_CALL && v->kind != EXPR_VARARG;
}

/* --- kill rules: a candidate survives only if every store to it is a single
 * numeric-plausible value on a path emit_maybe_store handles. --- */
static void maybe_kill_stmt(const Stmt *s, void *ctx) {
    SlotPass *p = ctx;
    CG *c = p->c;
    switch (s->kind) {
    case STMT_LOCAL: {
        int nn = s->as.local.n_names, nv = s->as.local.n_values;
        int last_call = nv > 0 && is_multival_tail(s->as.local.values[nv - 1]);
        int n_lead = last_call ? nv - 1 : nv;
        for (int j = 0; j < nn; j++) {
            int slot = s->as.local.local_idxs[j];
            if (s->as.local.attribs && s->as.local.attribs[j] == 2) {
                slot_kill(p, slot);
                continue;
            }
            /* A leading value, or a trailing call whose FIRST value lands on
             * exactly the last name (`local m = sqrt(x)`): a single store. */
            int single = j < n_lead || (last_call && j == nv - 1 && nn == nv);
            if (single && key_store_ok(c, slot, s->as.local.values[j]) &&
                expr_numeric_plausible(s->as.local.values[j]))
                continue;
            slot_kill(p, slot);
        }
        break;
    }
    case STMT_ASSIGN: {
        int nt = s->as.assign.n_targets, nv = s->as.assign.n_values;
        for (int j = 0; j < nt; j++) {
            AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind != TGT_VAR || t->as.var.kind != VAR_LOCAL) continue;
            if (nt == 1 && nv == 1 && key_store_ok(c, t->as.var.idx, s->as.assign.values[0]) &&
                expr_numeric_plausible(s->as.assign.values[0]))
                continue;
            slot_kill(p, t->as.var.idx);
        }
        break;
    }
    case STMT_FOR_NUM: slot_kill(p, s->as.for_num.local_idx); break;
    case STMT_FOR_GEN:
        for (int j = 0; j < s->as.for_gen.n_names; j++) slot_kill(p, s->as.for_gen.local_idxs[j]);
        break;
    case STMT_LOCAL_FUNC: slot_kill(p, s->as.local_func.local_idx); break;
    default: break;
    }
}

/* Fill out[] with the maybe-typed slots of one body. Run AFTER the int and
 * float analyses (both bitmaps live on c). Candidates: non-parameter,
 * non-captured, not already typed, read at least once in a numeric position;
 * then the kill fixpoint over stores. */
void compute_maybe_slots(CG *c, const Block *body, int n_locals, int n_params,
                         const unsigned char *captured, unsigned char *out) {
    NumUse u = {.use = xcalloc(n_locals, 1), .key = xcalloc(n_locals, 1), .n = n_locals};
    walk_block_exprs(body, numuse_visit, &u);
    /* Parameters are candidates too (classified at entry), but not on key use
     * alone: classifying on every call doesn't pay for a single unboxed key
     * (e.g. a sort comparator's `py[a] < py[b]`). A local's store is the
     * table read itself, which the cell reader classifies for free. */
    for (int i = 0; i < n_locals; i++) {
        out[i] = !(captured && captured[i]) &&
                 !(c->cur_is_int && c->cur_is_int[i]) && !(c->cur_is_float && c->cur_is_float[i]) &&
                 (u.use[i] || (u.key[i] && i >= n_params));
    }
    for (int i = 0; i < n_locals; i++) u.key[i] = u.key[i] && !u.use[i];
    free(u.use);
    int saved_n = c->cur_n_locals;
    c->cur_n_locals = n_locals;
    c->maybe_key_only = u.key;
    SlotPass p = {.c = c, .out = out, .changed = 1};
    while (p.changed) {
        p.changed = 0;
        walk_stmts(body, maybe_kill_stmt, &p);
    }
    c->maybe_key_only = NULL;
    free(u.key);
    c->cur_n_locals = saved_n;
}

/* Mark the local slots an assignment statement stores to. */
typedef struct {
    unsigned char *reassigned;
    int n;
} Reassigned;
static void mark_reassigned_visit(const Stmt *s, void *ctx) {
    Reassigned *r = ctx;
    if (s->kind != STMT_ASSIGN) return;
    for (int j = 0; j < s->as.assign.n_targets; j++) {
        const AssignTarget *t = &s->as.assign.targets[j];
        if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL && t->as.var.idx >= 0 && t->as.var.idx < r->n)
            r->reassigned[t->as.var.idx] = 1;
    }
}

/* ----- global function-binding maps (direct-call resolution) -----
 *
 * For every function (and main) record which LuaFunc each local slot and each
 * upvalue stably resolves to. A binding is stable iff the slot is never
 * reassigned — neither directly (an assignment to the local) nor through an
 * upvalue in any descendant closure. Captured slots are *kept* (unlike the old
 * per-body scan), so a self-recursive `local function f` — which captures itself
 * as an upvalue — is a direct-call target both inside its body (the upvalue) and
 * from its defining scope (the captured local). Reassignment via upvalue is what
 * the captured-exclusion used to guard against; we now check it precisely. */

typedef struct {
    const LuaFunc **slot_func;  /* [n_locals]  slot -> bound LuaFunc (or NULL) */
    unsigned char *reass_local; /* [n_locals]  slot assigned somewhere in body */
    unsigned char *reass_upval; /* [n_upvalues] upvalue assigned in body (or NULL) */
    int n_locals, n_upvalues;
} BindAccum;

static void bind_visit(const Stmt *s, void *ctx) {
    BindAccum *a = ctx;
    switch (s->kind) {
    case STMT_LOCAL_FUNC: {
        int sl = s->as.local_func.local_idx;
        if (sl >= 0 && sl < a->n_locals) a->slot_func[sl] = s->as.local_func.func;
        break;
    }
    case STMT_LOCAL:
        if (s->as.local.n_values == s->as.local.n_names)
            for (int j = 0; j < s->as.local.n_names; j++)
                if (s->as.local.values[j]->kind == EXPR_FUNCTION) {
                    int sl = s->as.local.local_idxs[j];
                    if (sl >= 0 && sl < a->n_locals)
                        a->slot_func[sl] = s->as.local.values[j]->as.func_expr.func;
                }
        break;
    case STMT_ASSIGN:
        for (int j = 0; j < s->as.assign.n_targets; j++) {
            AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind != TGT_VAR) continue;
            if (t->as.var.kind == VAR_LOCAL && t->as.var.idx >= 0 && t->as.var.idx < a->n_locals)
                a->reass_local[t->as.var.idx] = 1;
            else if (t->as.var.kind == VAR_UPVAL && a->reass_upval && t->as.var.idx >= 0 && t->as.var.idx < a->n_upvalues)
                a->reass_upval[t->as.var.idx] = 1;
        }
        break;
    default: break; /* nested function literals are walked on their own row */
    }
}

/* The slot_func map (and its length) for a given enclosing scope; func_idx == -1
 * is the main chunk. */
static const LuaFunc **bind_slot_map(CG *c, int func_idx, int *n_out) {
    if (func_idx == -1) {
        *n_out = c->pr->main_n_locals;
        return c->main_slot_func;
    }
    if (func_idx < 0 || func_idx >= c->n_sigs) {
        *n_out = 0;
        return NULL;
    }
    *n_out = c->pr->funcs.items[func_idx]->n_locals;
    return c->bind_slot[func_idx];
}

/* Trace upvalue u of function func_idx back to the (scope, local-slot) where it
 * originates. *of == -1 means the main chunk; *of == -2 means unresolvable. */
void resolve_upval_origin(CG *c, int func_idx, int u, int *of, int *os) {
    const LuaFunc *F = c->pr->funcs.items[func_idx];
    if (!F->upvalues || u < 0 || u >= F->n_upvalues) {
        *of = -2;
        *os = -1;
        return;
    }
    UpvalueRef ref = F->upvalues[u];
    if (ref.src == UPVAL_FROM_LOCAL) {
        *of = F->parent_idx;
        *os = ref.idx;
    } else if (F->parent_idx >= 0) resolve_upval_origin(c, F->parent_idx, ref.idx, of, os);
    else {
        *of = -2;
        *os = -1;
    } /* main has no upvalues */
}

/* Build c->bind_slot / c->bind_upval / c->main_slot_func. */
void compute_func_bindings(CG *c, const ParseResult *pr) {
    int n = (int)pr->funcs.count;
    c->n_binds = n; /* free_func_bindings frees exactly this many rows */
    c->bind_slot = xcalloc(n, sizeof *c->bind_slot);
    c->bind_upval = xcalloc(n, sizeof *c->bind_upval);
    c->main_slot_func = xcalloc(pr->main_n_locals, sizeof(const LuaFunc *));
    unsigned char **reass_upval = xcalloc(n, sizeof *reass_upval);

    /* Pass 1: per-scope bindings; drop directly-reassigned local bindings. */
    {
        unsigned char *rl = xcalloc(pr->main_n_locals, 1);
        BindAccum a = {c->main_slot_func, rl, NULL, pr->main_n_locals, 0};
        walk_stmts(&pr->main_body, bind_visit, &a);
        for (int s = 0; s < pr->main_n_locals; s++)
            if (rl[s]) c->main_slot_func[s] = NULL;
        free(rl);
    }
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        c->bind_slot[f] = xcalloc(F->n_locals, sizeof(const LuaFunc *));
        c->bind_upval[f] = xcalloc(F->n_upvalues, sizeof(const LuaFunc *));
        reass_upval[f] = xcalloc(F->n_upvalues, 1);
        unsigned char *rl = xcalloc(F->n_locals, 1);
        BindAccum a = {c->bind_slot[f], rl, reass_upval[f], F->n_locals, F->n_upvalues};
        walk_stmts(&F->body, bind_visit, &a);
        for (int s = 0; s < F->n_locals; s++)
            if (rl[s]) c->bind_slot[f][s] = NULL;
        free(rl);
    }

    /* Pass 2: a slot reassigned through an upvalue in any descendant is unstable
     * at its origin too. */
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        for (int u = 0; u < F->n_upvalues; u++) {
            if (!reass_upval[f][u]) continue;
            int of, os;
            resolve_upval_origin(c, f, u, &of, &os);
            int nn;
            const LuaFunc **m = bind_slot_map(c, of, &nn);
            if (m && os >= 0 && os < nn) m[os] = NULL;
        }
    }

    /* Pass 3: resolve each upvalue to its (now-finalized) bound function. */
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        for (int u = 0; u < F->n_upvalues; u++) {
            int of, os;
            resolve_upval_origin(c, f, u, &of, &os);
            int nn;
            const LuaFunc **m = bind_slot_map(c, of, &nn);
            c->bind_upval[f][u] = (m && os >= 0 && os < nn) ? m[os] : NULL;
        }
        free(reass_upval[f]);
    }
    free(reass_upval);
}

void free_func_bindings(CG *c) {
    if (c->bind_slot)
        for (int i = 0; i < c->n_binds; i++) free((void *)c->bind_slot[i]);
    if (c->bind_upval)
        for (int i = 0; i < c->n_binds; i++) free((void *)c->bind_upval[i]);
    free(c->bind_slot);
    c->bind_slot = NULL;
    free(c->bind_upval);
    c->bind_upval = NULL;
    free(c->main_slot_func);
    c->main_slot_func = NULL;
    c->n_binds = 0;
}

/* ----- whole-program signature inference (param + return unboxing) -----
 *
 * A monotone fixpoint over all functions (and the main chunk). Each parameter
 * starts at NT_UNSET and is narrowed by meeting it with the argument type at
 * every direct-call site; each function's single-value return type is recomputed
 * from its body each round. The lattice only moves downward, so iteration
 * terminates. Reading not-yet-final values mid-fixpoint is sound for the same
 * reason the per-function int-slot fixpoint above is: contradictions propagate
 * and re-narrow on the next round.
 *
 * The inferred signature only types the dedicated $user_N_da/_da1 entries; a
 * call site uses them only when its arguments are typed-ok (direct_args_typed_ok),
 * otherwise it falls back to the fully generic path — so over-typing is never
 * unsound, just occasionally a missed fast path. */

static NumTy num_meet(NumTy a, NumTy b) {
    if (a == NT_UNSET) return b;
    if (b == NT_UNSET) return a;
    return a == b ? a : NT_ANY; /* INT vs FLOAT (or any disagreement) -> ANY */
}

/* Does every path through the block end in a `return`? Conservative: only the
 * trailing statement is examined (an if/else both of whose arms always return,
 * a do-block, or a literal return). */
static int block_always_returns(const Block *b);
static int stmt_always_returns(const Stmt *s) {
    switch (s->kind) {
    case STMT_RETURN: return 1;
    case STMT_DO: return block_always_returns(&s->as.do_stmt.body);
    case STMT_IF:
        if (!s->as.if_stmt.has_else) return 0;
        for (size_t a = 0; a < s->as.if_stmt.narms; a++)
            if (!block_always_returns(&s->as.if_stmt.arms[a].body)) return 0;
        return block_always_returns(&s->as.if_stmt.else_body);
    default: return 0;
    }
}
static int block_always_returns(const Block *b) {
    return b->count > 0 && stmt_always_returns(b->items[b->count - 1]);
}

/* Meet every return's value type into *acc (NT_UNSET is the identity). A return
 * that isn't a single numeric value, or that disagrees with another (int vs
 * float), folds *acc to NT_ANY. Skips nested functions. */
typedef struct {
    CG *c;
    NumTy acc;
} RetScan;
static void ret_scan_visit(const Stmt *s, void *ctx) {
    RetScan *r = ctx;
    if (s->kind != STMT_RETURN) return;
    r->acc = num_meet(r->acc, s->as.return_stmt.n_values == 1 ? expr_num_ty(r->c, s->as.return_stmt.values[0])
                                                              : NT_ANY);
}

/* Single-value return type of fn in the current context, or NT_ANY when the
 * function may fall through (return nil) or its returns aren't one shared
 * numeric type. */
static NumTy compute_ret_ty(CG *c, const LuaFunc *fn) {
    if (!block_always_returns(&fn->body)) return NT_ANY;
    RetScan r = {c, NT_UNSET};
    walk_stmts(&fn->body, ret_scan_visit, &r);
    return r.acc == NT_UNSET ? NT_ANY : r.acc; /* UNSET only if no returns at all */
}

/* Walk a body in the current context and, at each direct-call site, narrow the
 * callee's parameter types by meeting them with the argument types here. */
static void infer_sites_expr(CG *c, const Expr *e, int *changed) {
    if (!e) return;
    switch (e->kind) {
    case EXPR_CALL: {
        infer_sites_expr(c, e->as.call.callee, changed);
        for (size_t i = 0; i < e->as.call.nargs; i++)
            infer_sites_expr(c, e->as.call.args[i], changed);
        const LuaFunc *K = direct_call_target(c, e);
        if (K && K->func_idx >= 0 && K->func_idx < c->n_sigs) {
            FuncSig *sg = &c->sigs[K->func_idx];
            sg->has_site = 1;
            for (size_t i = 0; i < e->as.call.nargs && (int)i < sg->n_params; i++) {
                if (sg->param_ty[i] == NT_ANY) continue;
                NumTy nw = num_meet(sg->param_ty[i], expr_num_ty(c, e->as.call.args[i]));
                if (nw != sg->param_ty[i]) {
                    sg->param_ty[i] = nw;
                    *changed = 1;
                }
            }
        }
        return;
    }
    case EXPR_METHOD_CALL:
        infer_sites_expr(c, e->as.method_call.recv, changed);
        for (size_t i = 0; i < e->as.method_call.nargs; i++)
            infer_sites_expr(c, e->as.method_call.args[i], changed);
        return;
    case EXPR_BINOP:
        infer_sites_expr(c, e->as.binop.lhs, changed);
        infer_sites_expr(c, e->as.binop.rhs, changed);
        return;
    case EXPR_UNOP: infer_sites_expr(c, e->as.unop.operand, changed); return;
    case EXPR_INDEX:
        infer_sites_expr(c, e->as.index.table, changed);
        infer_sites_expr(c, e->as.index.key, changed);
        return;
    case EXPR_TABLE:
        for (int i = 0; i < e->as.table_ctor.n_entries; i++) {
            infer_sites_expr(c, e->as.table_ctor.entries[i].key, changed);
            infer_sites_expr(c, e->as.table_ctor.entries[i].value, changed);
        }
        return;
    default: return; /* EXPR_FUNCTION bodies are walked on their own row */
    }
}
typedef struct {
    CG *c;
    int *changed;
} SiteInfer;
static void infer_sites_visit(const Expr *e, void *ctx) {
    SiteInfer *si = ctx;
    infer_sites_expr(si->c, e, si->changed);
}
static void infer_sites_block(CG *c, const Block *b, int *changed) {
    walk_block_exprs(b, infer_sites_visit, &(SiteInfer){c, changed});
}

/* One fixpoint step for a single function/main body: rebuild its analysis
 * context from current signatures + the global binding maps, then narrow
 * callees' params and (for a real function) recompute its own return type.
 * func_idx == -1 is the main chunk. */
static void infer_step_body(CG *c, const Block *body, int n_locals, int n_params,
                            const unsigned char *captured, const NumTy *param_seed,
                            const LuaFunc *fn, int func_idx, int *changed) {
    const unsigned char *p_int = c->cur_is_int, *p_float = c->cur_is_float;
    const LuaFunc **p_fs = c->cur_func_slot, **p_uv = c->cur_upval_func;
    int p_nl = c->cur_n_locals, p_np = c->cur_n_params, p_fi = c->cur_func_idx;

    unsigned char *isint = xcalloc(n_locals, 1);
    unsigned char *isfloat = xcalloc(n_locals, 1);
    int nn;
    c->cur_func_slot = bind_slot_map(c, func_idx, &nn);
    c->cur_upval_func = func_idx >= 0 ? c->bind_upval[func_idx] : NULL;
    c->cur_func_idx = func_idx;
    c->cur_n_locals = n_locals;
    c->cur_n_params = n_params;
    compute_int_slots(c, body, n_locals, n_params, captured, isint, param_seed);
    c->cur_is_int = isint;
    compute_float_slots(c, body, n_locals, n_params, captured, isfloat, param_seed);
    c->cur_is_float = isfloat;

    infer_sites_block(c, body, changed);
    if (fn) {
        NumTy r = compute_ret_ty(c, fn);
        if (r != c->sigs[fn->func_idx].ret_ty) {
            c->sigs[fn->func_idx].ret_ty = r;
            *changed = 1;
        }
    }

    c->cur_is_int = p_int;
    c->cur_is_float = p_float;
    c->cur_func_slot = p_fs;
    c->cur_upval_func = p_uv;
    c->cur_n_locals = p_nl;
    c->cur_n_params = p_np;
    c->cur_func_idx = p_fi;
    free(isint);
    free(isfloat);
}

/* Allocate and infer c->sigs for every user function. */
void infer_signatures(CG *c, const ParseResult *pr) {
    int n = (int)pr->funcs.count;
    c->n_sigs = n;
    c->sigs = xcalloc(n, sizeof *c->sigs);
    for (int i = 0; i < n; i++) {
        const LuaFunc *fn = pr->funcs.items[i];
        FuncSig *sg = &c->sigs[i];
        sg->n_params = fn->n_params;
        sg->ret_ty = NT_INT; /* optimistic; narrows downward */
        sg->has_site = 0;
        sg->param_ty = fn->n_params ? xcalloc(fn->n_params, sizeof(NumTy)) : NULL;
        /* A parameter is eligible for unboxing only if it is never reassigned
         * and never captured; others are pinned to NT_ANY. */
        int nl = fn->n_locals;
        unsigned char *reassigned = xcalloc(nl, 1);
        walk_stmts(&fn->body, mark_reassigned_visit, &(Reassigned){reassigned, nl});
        for (int p = 0; p < fn->n_params; p++) {
            int pinned = reassigned[p] || (fn->captured && fn->captured[p]);
            sg->param_ty[p] = pinned ? NT_ANY : NT_UNSET; /* narrowed by sites */
        }
        free(reassigned);
    }

    int changed = 1;
    while (changed) {
        changed = 0;
        for (int i = 0; i < n; i++) {
            const LuaFunc *fn = pr->funcs.items[i];
            infer_step_body(c, &fn->body, fn->n_locals, fn->n_params, fn->captured,
                            c->sigs[i].param_ty, fn, i, &changed);
        }
        infer_step_body(c, &pr->main_body, pr->main_n_locals, 0, pr->main_captured,
                        NULL, NULL, -1, &changed);
    }

    /* Finalize: a parameter with no narrowing evidence (NT_UNSET) becomes ANY,
     * and a function nothing direct-calls keeps its (dead) entries fully boxed —
     * matching the pre-unboxing output and avoiding stray unreachable entries. */
    for (int i = 0; i < n; i++) {
        FuncSig *sg = &c->sigs[i];
        if (!sg->has_site) {
            for (int p = 0; p < sg->n_params; p++) sg->param_ty[p] = NT_ANY;
            sg->ret_ty = NT_ANY;
        } else {
            for (int p = 0; p < sg->n_params; p++)
                if (sg->param_ty[p] == NT_UNSET) sg->param_ty[p] = NT_ANY;
        }
    }
}

void free_signatures(CG *c) {
    if (!c->sigs) return;
    for (int i = 0; i < c->n_sigs; i++) free(c->sigs[i].param_ty);
    free(c->sigs);
    c->sigs = NULL;
    c->n_sigs = 0;
}
