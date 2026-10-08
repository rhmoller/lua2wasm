/* Expression emission: literals, variables and assignment targets, operators
 * and comparisons, calls and tail calls, closures, table reads and
 * constructors, and the unboxed int / float expression trees. */
#include "internal.h"

/* ----- literal emission ----- */
static void emit_int_literal(CG *c, int64_t v, int depth) {
    emit_indent(c, depth);
    if (i31_fits(v)) {
        wat_appendf(c->w, "(ref.i31 (i32.const %lld))\n", (long long)v);
    } else {
        wat_appendf(c->w, "(struct.new $LuaInt (i64.const %lld))\n", (long long)v);
    }
}

static void emit_float_literal(CG *c, double v, int depth) {
    emit_linef(c, depth, "(struct.new $LuaFloat (f64.const %.17g))\n", v);
}

/* A fresh inline cache for a constant-key access site, as the expression
 * passing it (`(global.get $ic_N)`), or NULL when the specializer is off
 * (-O0 keeps the uncached setters/getters). */
const char *ic_new(CG *c, char *buf, size_t bufsz) {
    if (!c->opt_int) return NULL;
    snprintf(buf, bufsz, "(global.get $ic_%d)", c->n_ics++);
    return buf;
}

/* Emit a constant string as one folded line indented to `depth`. */
void emit_string_literal(CG *c, const char *bytes, size_t len, int depth) {
    char eb[160];
    emit_linef(c, depth, "%s\n", kstr_expr(c, bytes, len, eb, sizeof eb));
}

/* ----- variable read / write -----
 * VAR_UPVAL is only emitted inside user functions (parser guarantees this:
 * main has no upvalues to capture).
 */
/* Emit the constant-string key carrying the name of a global (one line, no
 * indentation). Used by every global read/write. */
void emit_global_key(CG *c, const char *name, size_t name_len) {
    char eb[160];
    wat_appendf(c->w, "%s\n", kstr_expr(c, name, name_len, eb, sizeof eb));
}

static void emit_global_read(CG *c, const char *name, size_t name_len, int depth) {
    emit_line(c, depth, "(call $tab_get (ref.as_non_null (global.get $g_globals))\n");
    emit_indent(c, depth + 1);
    emit_global_key(c, name, name_len);
    emit_line(c, depth, ")\n");
}

static void emit_var_read(CG *c, VarKind kind, int idx, int depth) {
    switch (kind) {
    case VAR_LOCAL:
        if (slot_is_maybe(c, idx)) {
            emit_maybe_slot_box(c, idx, depth);
            break;
        }
        emit_indent(c, depth);
        if (slot_is_boxed(c, idx)) {
            wat_appendf(c->w, "(struct.get $Box $v (local.get $L%d))\n", idx);
        } else {
            wat_appendf(c->w, "(local.get $L%d)\n", idx);
        }
        break;
    case VAR_UPVAL:
        emit_linef(c, depth, "(struct.get $Box $v (array.get $UpvalArr "
                             "(struct.get $LuaClosure $upvals (local.get $closure)) "
                             "(i32.const %d)))\n",
                   idx);
        break;
    case VAR_BUILTIN: {
        /* Read via $g_globals so user reassignment is honoured. */
        const char *name = builtin_name(idx);
        emit_global_read(c, name, strlen(name), depth);
        break;
    }
    case VAR_GLOBAL: {
        const char *name = c->pr->globals.items[idx].name;
        size_t nl = c->pr->globals.items[idx].name_len;
        emit_global_read(c, name, nl, depth);
        break;
    }
    }
}

/* Emit code that pushes the (ref $Box) for the named binding (not its value).
 * Used for upvalue capture into a child closure. Globals and builtins don't
 * have boxes. Invariant: any local reached here must have been flagged
 * captured during name resolution, so it really is boxed at codegen time. */
static void emit_box_ref(CG *c, VarKind kind, int idx, int depth) {
    emit_indent(c, depth);
    switch (kind) {
    case VAR_LOCAL:
        if (!slot_is_boxed(c, idx)) {
            cg_error(c, "internal: emit_box_ref on unboxed local");
            return;
        }
        wat_appendf(c->w, "(local.get $L%d)\n", idx);
        break;
    case VAR_UPVAL:
        wat_appendf(c->w,
                    "(array.get $UpvalArr "
                    "(struct.get $LuaClosure $upvals (local.get $closure)) "
                    "(i32.const %d))\n",
                    idx);
        break;
    case VAR_BUILTIN:
    case VAR_GLOBAL:
        cg_error(c, "cannot take a box reference to a builtin/global");
        break;
    }
}

/* Open the "store to this target" expression. The caller must then emit the
 * value expression as a child, then call emit_target_close(). */
void emit_target_open(CG *c, const AssignTarget *t, int depth) {
    if (t->kind == TGT_VAR) {
        switch (t->as.var.kind) {
        case VAR_LOCAL:
            if (slot_is_maybe(c, t->as.var.idx)) {
                /* The analysis kills a maybe slot on every multi-value store
                 * path, so only single stores (emit_maybe_store) reach one. */
                cg_error(c, "internal: maybe-typed slot in a generic store");
                return;
            }
            if (slot_is_boxed(c, t->as.var.idx)) {
                emit_line(c, depth, "(struct.set $Box $v\n");
                emit_box_ref(c, VAR_LOCAL, t->as.var.idx, depth + 1);
            } else {
                emit_linef(c, depth, "(local.set $L%d\n", t->as.var.idx);
            }
            break;
        case VAR_UPVAL:
            emit_line(c, depth, "(struct.set $Box $v\n");
            emit_box_ref(c, t->as.var.kind, t->as.var.idx, depth + 1);
            break;
        case VAR_BUILTIN:
        case VAR_GLOBAL: {
            /* Assignment to any global (including a name that
             * happens to also be a builtin like `print`) routes
             * through $g_globals via $tab_set. */
            const char *name;
            size_t name_len;
            if (t->as.var.kind == VAR_BUILTIN) {
                name = builtin_name(t->as.var.idx);
                name_len = strlen(name);
            } else {
                name = c->pr->globals.items[t->as.var.idx].name;
                name_len = c->pr->globals.items[t->as.var.idx].name_len;
            }
            emit_line(c, depth, "(call $tab_set (ref.as_non_null (global.get $g_globals))\n");
            emit_indent(c, depth + 1);
            emit_global_key(c, name, name_len);
            break;
        }
        }
    } else if (t->as.index.key->kind == EXPR_STRING && t->as.index.key->as.s.len <= KSTR_MAX) {
        /* Constant string key: $lua_tabset_sk stores to the hash part directly
         * when there is no metatable, else dispatches __newindex; the
         * inline-cached $lua_tabset_ic first tries the site's cached slot. */
        char icb[48];
        const char *ic = ic_new(c, icb, sizeof icb);
        emit_indent(c, depth);
        if (ic) wat_appendf(c->w, "(call $lua_tabset_ic %s\n", ic);
        else wat_append(c->w, "(call $lua_tabset_sk\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_string_literal(c, t->as.index.key->as.s.bytes, t->as.index.key->as.s.len, depth + 1);
    } else if (t->as.index.key->kind == EXPR_VAR && t->as.index.key->as.var.kind == VAR_LOCAL &&
               slot_is_maybe(c, t->as.index.key->as.var.idx)) {
        MCell k = mcell_slot(t->as.index.key->as.var.idx);
        emit_line(c, depth, "(call $lua_tabset_mk\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_linef(c, depth + 1, "%s %s %s %s\n", k.t, k.i, k.f, k.b);
    } else if (c->opt_int && expr_is_int(c, t->as.index.key)) {
        /* Int-typed key: $lua_tabset_ik takes the raw i64 (no make_int /
         * $as_arr_key) and still dispatches __newindex. The value is emitted
         * by the caller between open and close. */
        emit_line(c, depth, "(call $lua_tabset_ik\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_int_expr(c, t->as.index.key, depth + 1);
    } else {
        /* User-code assignment goes through \$lua_tabset so __newindex
         * has a chance to fire. Table constructors emit \$tab_set
         * directly since freshly built tables have no metatable. */
        emit_line(c, depth, "(call $lua_tabset\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_expr(c, t->as.index.key, depth + 1);
    }
}
/* Close an emit_target_open() expression. The target is the same one passed to
 * open, but every target shape closes with a single `)`, so it isn't needed. */
void emit_target_close(CG *c, int depth) {
    emit_line(c, depth, ")\n");
}

/* ----- binary / unary ops ----- */
const char *binop_helper(BinOp op) {
    switch (op) {
    case BIN_ADD: return "$lua_add";
    case BIN_SUB: return "$lua_sub";
    case BIN_MUL: return "$lua_mul";
    case BIN_DIV: return "$lua_div";
    case BIN_FDIV: return "$lua_fdiv";
    case BIN_MOD: return "$lua_mod";
    case BIN_POW: return "$lua_pow";
    case BIN_CONCAT: return "$lua_concat";
    case BIN_EQ: return "$lua_eq";
    case BIN_NEQ: return "$lua_neq";
    case BIN_LT: return "$lua_lt";
    case BIN_LE: return "$lua_le";
    case BIN_GT: return "$lua_gt";
    case BIN_GE: return "$lua_ge";
    case BIN_BAND: return "$lua_band";
    case BIN_BOR: return "$lua_bor";
    case BIN_BXOR: return "$lua_bxor";
    case BIN_SHL: return "$lua_shl";
    case BIN_SHR: return "$lua_shr";
    /* BIN_AND / BIN_OR are short-circuiting and handled in emit_binop
     * before reaching here; any other value is a codegen bug. */
    default: return NULL;
    }
}

/* ----- comparisons ----- */

int is_cmp_op(BinOp op) {
    switch (op) {
    case BIN_LT:
    case BIN_LE:
    case BIN_GT:
    case BIN_GE:
    case BIN_EQ:
    case BIN_NEQ: return 1;
    default: return 0;
    }
}

/* The spellings of comparison operator `op` (is_cmp_op). */
const CmpOp *cmp_op(BinOp op) {
    static const CmpOp LT = {"i64.lt_s", "f64.lt", "$int_lt_float", "$float_lt_int", 0};
    static const CmpOp LE = {"i64.le_s", "f64.le", "$int_le_float", "$float_le_int", 0};
    static const CmpOp GT = {"i64.gt_s", "f64.gt", "$int_gt_float", "$float_gt_int", 0};
    static const CmpOp GE = {"i64.ge_s", "f64.ge", "$int_ge_float", "$float_ge_int", 0};
    static const CmpOp EQ = {"i64.eq", "f64.eq", "$int_eq_float", "$float_eq_int", 0};
    static const CmpOp NE = {"i64.ne", "f64.ne", "$int_eq_float", "$float_eq_int", 1};
    switch (op) {
    case BIN_LT: return &LT;
    case BIN_LE: return &LE;
    case BIN_GT: return &GT;
    case BIN_GE: return &GE;
    case BIN_EQ: return &EQ;
    default: return &NE;
    }
}

/* An integer literal that converts to f64 exactly (|v| <= 2^53), so comparing
 * it with a float as two doubles gives Lua's exact int-vs-float answer. */
int expr_is_exact_f64_int_literal(const Expr *e) {
    const int64_t lim = (int64_t)1 << 53;
    return e->kind == EXPR_INT && e->as.i_val >= -lim && e->as.i_val <= lim;
}

/* The operand types of a comparison whose operands are both unboxed numbers
 * (CMP_NONE when they aren't). */
typedef enum { CMP_NONE,
               CMP_INT,
               CMP_FLOAT,
               CMP_INT_FLOAT,
               CMP_FLOAT_INT } CmpKind;

static CmpKind cmp_numeric_kind(CG *c, const Expr *e) {
    if (!c->opt_int || e->kind != EXPR_BINOP || !is_cmp_op(e->as.binop.op)) return CMP_NONE;
    const Expr *l = e->as.binop.lhs, *r = e->as.binop.rhs;
    if (expr_is_int(c, l) && expr_is_int(c, r)) return CMP_INT;
    if (expr_is_float(c, l) && expr_is_float(c, r)) return CMP_FLOAT;
    if (expr_is_int(c, l) && expr_is_float(c, r)) return CMP_INT_FLOAT;
    if (expr_is_float(c, l) && expr_is_int(c, r)) return CMP_FLOAT_INT;
    return CMP_NONE;
}

/* Emit a typed numeric comparison (cmp_numeric_kind != CMP_NONE) as a raw
 * i32. An int-vs-float one is an f64 compare when the integer is a literal
 * that converts exactly, else the exact mixed helper. */
static void emit_cmp_i32(CG *c, const Expr *e, int depth, CmpKind kind) {
    const CmpOp *op = cmp_op(e->as.binop.op);
    const Expr *l = e->as.binop.lhs, *r = e->as.binop.rhs;
    if (kind == CMP_INT_FLOAT || kind == CMP_FLOAT_INT) {
        int int_left = kind == CMP_INT_FLOAT;
        if (expr_is_exact_f64_int_literal(int_left ? l : r)) {
            emit_linef(c, depth, "(%s\n", op->f64);
            emit_num_as_f64(c, l, depth + 1);
            emit_num_as_f64(c, r, depth + 1);
        } else {
            emit_linef(c, depth, "%s(call %s\n", op->negate ? "(i32.eqz " : "",
                       int_left ? op->int_float : op->float_int);
            if (int_left) {
                emit_int_expr(c, l, depth + 1);
                emit_float_expr(c, r, depth + 1);
            } else {
                emit_float_expr(c, l, depth + 1);
                emit_int_expr(c, r, depth + 1);
            }
            if (op->negate) emit_line(c, depth, ")\n");
        }
        emit_line(c, depth, ")\n");
        return;
    }
    emit_linef(c, depth, "(%s\n", kind == CMP_INT ? op->i64 : op->f64);
    if (kind == CMP_INT) {
        emit_int_expr(c, e->as.binop.lhs, depth + 1);
        emit_int_expr(c, e->as.binop.rhs, depth + 1);
    } else {
        emit_num_as_f64(c, e->as.binop.lhs, depth + 1);
        emit_num_as_f64(c, e->as.binop.rhs, depth + 1);
    }
    emit_line(c, depth, ")\n");
}

/* Emit `e` as an i32 truthiness (0/1). A numeric comparison becomes a direct
 * iXX/fXX compare, skipping the boxed boolean and $lua_truthy. */
void emit_truthy(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_BINOP && is_cmp_op(e->as.binop.op) && expr_involves_maybe(c, e)) {
        emit_maybe_cmp_block(c, e, depth);
        return;
    }
    CmpKind k = cmp_numeric_kind(c, e);
    if (k) {
        emit_cmp_i32(c, e, depth, k);
        return;
    }
    emit_expr(c, e, depth);
    emit_line(c, depth, "(call $lua_truthy)\n");
}

/* Concatenate `parts[0..k)` (already in source order): up to four at once
 * ($lua_concat / 3 / 4), a longer chain as its first three plus the rest. */
static void emit_concat_parts(CG *c, const Expr *const *parts, int k, int depth) {
    emit_line(c, depth, k == 2 ? "(call $lua_concat\n" : k == 3 ? "(call $lua_concat3\n"
                                                                : "(call $lua_concat4\n");
    int direct = k <= 4 ? k : 3;
    for (int i = 0; i < direct; i++) emit_expr(c, parts[i], depth + 1);
    if (k > 4) emit_concat_parts(c, parts + 3, k - 3, depth + 1);
    emit_line(c, depth, ")\n");
}

static void emit_binop(CG *c, const Expr *e, int depth) {
    BinOp op = e->as.binop.op;
    if (op == BIN_AND || op == BIN_OR) {
        int label = c->next_label++;
        emit_linef(c, depth, "(block $sc_%d (result anyref)\n", label);

        emit_expr(c, e->as.binop.lhs, depth + 1);
        emit_line(c, depth + 1, "local.set $tmp_any\n");
        emit_line(c, depth + 1, "(call $lua_truthy (local.get $tmp_any))\n");
        emit_line(c, depth + 1, "(if (then\n");
        if (op == BIN_AND) {
            emit_expr(c, e->as.binop.rhs, depth + 2);
            emit_linef(c, depth + 2, "br $sc_%d\n", label);
            emit_line(c, depth + 1, "))\n");
            emit_line(c, depth + 1, "local.get $tmp_any\n");
        } else {
            emit_line(c, depth + 2, "local.get $tmp_any\n");
            emit_linef(c, depth + 2, "br $sc_%d\n", label);
            emit_line(c, depth + 1, "))\n");
            emit_expr(c, e->as.binop.rhs, depth + 1);
        }
        emit_line(c, depth, ")\n");
        return;
    }
    if (expr_involves_maybe(c, e)) {
        if (is_cmp_op(op)) {
            emit_line(c, depth, "(select (result anyref)\n");
            emit_line(c, depth + 1, "(global.get $g_true)\n");
            emit_line(c, depth + 1, "(global.get $g_false)\n");
            emit_maybe_cmp_block(c, e, depth + 1);
            emit_line(c, depth, ")\n");
        } else {
            emit_maybe_boxed(c, e, depth);
        }
        return;
    }
    CmpKind ck = cmp_numeric_kind(c, e);
    if (ck) {
        /* Value context: materialize the i32 compare as a Lua boolean. */
        emit_line(c, depth, "(select (result anyref)\n");
        emit_line(c, depth + 1, "(global.get $g_true)\n");
        emit_line(c, depth + 1, "(global.get $g_false)\n");
        emit_cmp_i32(c, e, depth + 1, ck);
        emit_line(c, depth, ")\n");
        return;
    }
    if (op == BIN_CONCAT) {
        /* `a .. b .. c ...` parses right-nested; flatten the unparenthesized
         * right spine so the whole chain is built in one allocation. (A
         * parenthesized `(a .. b) .. c` keeps its grouping: with __concat
         * the order of the pairwise calls is observable.) */
        const Expr *parts[64];
        int k = 0;
        const Expr *cur = e;
        while (cur->kind == EXPR_BINOP && cur->as.binop.op == BIN_CONCAT && (cur == e || !cur->paren) &&
               k < 63) {
            parts[k++] = cur->as.binop.lhs;
            cur = cur->as.binop.rhs;
        }
        parts[k++] = cur;
        emit_concat_parts(c, parts, k, depth);
        return;
    }
    const char *helper = binop_helper(op);
    if (!helper) {
        cg_error(c, "internal: unhandled binary operator");
        return;
    }
    emit_expr(c, e->as.binop.lhs, depth);
    emit_expr(c, e->as.binop.rhs, depth);
    emit_linef(c, depth, "(call %s)\n", helper);
}

static void emit_unop(CG *c, const Expr *e, int depth) {
    if (e->as.unop.op == UN_NEG && expr_involves_maybe(c, e)) {
        emit_maybe_boxed(c, e, depth);
        return;
    }
    emit_expr(c, e->as.unop.operand, depth);
    emit_indent(c, depth);
    switch (e->as.unop.op) {
    case UN_NEG: wat_append(c->w, "(call $lua_neg)\n"); break;
    case UN_NOT: wat_append(c->w, "(call $lua_not)\n"); break;
    case UN_LEN: wat_append(c->w, "(call $lua_len)\n"); break;
    case UN_BNOT: wat_append(c->w, "(call $lua_bnot)\n"); break;
    }
}

/* ----- calls ----- */

/* An expression whose value in a multi-value position is a full $ArgArr
 * (call/method-call/vararg) rather than a single anyref. */
int is_multival_tail(const Expr *e) {
    if (e->paren) return 0; /* `(f())` is adjusted to a single value */
    return e->kind == EXPR_CALL ||
           e->kind == EXPR_METHOD_CALL ||
           e->kind == EXPR_VARARG;
}
void emit_multival_array(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_VARARG) {
        emit_line(c, depth, "(local.get $varargs)\n");
        return;
    }
    emit_call_array(c, e, depth);
}

/* If `e` is a call whose callee statically (and stably) resolves to a known
 * LuaFunc, invoked with exactly its parameter count and no multi-value-splat
 * argument, return that LuaFunc: the call can go to the direct entry
 * $user_N_da/_da1 and skip building an $ArgArr. Otherwise NULL.
 *
 *   - VAR_LOCAL: a never-reassigned local function, *including a captured one*
 *     (so a self-recursive `local function fib` is reachable from its defining
 *     scope, which bootstraps the typed recursion below).
 *   - VAR_UPVAL: only *self-recursion* (the upvalue resolves to the function
 *     being emitted). This makes recursive `local function`s like fib direct
 *     without making cross-function upvalue calls direct — the latter would
 *     skip the callee's frame and degrade error()/traceback positions. */
const LuaFunc *direct_call_target(CG *c, const Expr *e) {
    if (!c->opt_int || e->kind != EXPR_CALL) return NULL;
    const Expr *callee = e->as.call.callee;
    if (callee->kind != EXPR_VAR) return NULL;
    const LuaFunc *K = NULL;
    int idx = callee->as.var.idx;
    if (callee->as.var.kind == VAR_LOCAL) {
        if (c->cur_func_slot && idx >= 0 && idx < c->cur_n_locals) K = c->cur_func_slot[idx];
    } else if (callee->as.var.kind == VAR_UPVAL) {
        if (c->cur_upval_func && idx >= 0) {
            K = c->cur_upval_func[idx];
            if (K && K->func_idx != c->cur_func_idx) K = NULL; /* self-recursion only */
        }
    }
    if (!K || K->is_vararg || (int)e->as.call.nargs != K->n_params) return NULL;
    for (size_t i = 0; i < e->as.call.nargs; i++)
        if (is_multival_tail(e->as.call.args[i])) return NULL;
    return K;
}

/* The inferred signature of a direct-call target, or NULL when unavailable. */
const FuncSig *target_sig(CG *c, const LuaFunc *K) {
    if (!K || !c->sigs || K->func_idx < 0 || K->func_idx >= c->n_sigs) return NULL;
    return &c->sigs[K->func_idx];
}

/* The numeric type of `e` in the current context (NT_INT/NT_FLOAT/NT_ANY). */
NumTy expr_num_ty(CG *c, const Expr *e) {
    if (expr_is_int(c, e)) return NT_INT;
    if (expr_is_float(c, e)) return NT_FLOAT;
    return NT_ANY;
}

/* Can a direct call to K reach its typed _da/_da1 entry from here? Each argument
 * must be emittable at its parameter's declared numeric type (an f64 param also
 * accepts an int arg, which is converted at the call). When K's params are all
 * NT_ANY this is always true, matching the original (untyped) direct-args path. */
int direct_args_typed_ok(CG *c, const Expr *e, const LuaFunc *K) {
    const FuncSig *sg = target_sig(c, K);
    if (!sg) return 0;
    for (size_t i = 0; i < e->as.call.nargs; i++) {
        NumTy pt = sg->param_ty ? sg->param_ty[i] : NT_ANY;
        const Expr *a = e->as.call.args[i];
        if (pt == NT_INT && !expr_is_int(c, a)) return 0;
        if (pt == NT_FLOAT && !expr_is_int(c, a) && !expr_is_float(c, a)) return 0;
    }
    return 1;
}

/* Emit each argument of a direct call at its parameter's declared numeric type:
 * a raw i64 for NT_INT, a raw f64 for NT_FLOAT, else a boxed anyref. */
static void emit_typed_args(CG *c, const Expr *e, const FuncSig *sg, int depth) {
    for (size_t i = 0; i < e->as.call.nargs; i++) {
        NumTy pt = (sg && sg->param_ty) ? sg->param_ty[i] : NT_ANY;
        const Expr *a = e->as.call.args[i];
        if (pt == NT_INT) emit_int_expr(c, a, depth);
        else if (pt == NT_FLOAT) emit_num_as_f64(c, a, depth);
        else emit_expr(c, a, depth);
    }
}

/* Emit a direct call to K's single-value entry $user_K_da1 (closure + typed
 * args). The result lands as the entry's declared type: raw i64/f64 when K has a
 * numeric ret_ty, otherwise a single anyref. Callers ensure args are typed-ok. */
void emit_typed_direct_call1(CG *c, const Expr *e, const LuaFunc *K, int depth) {
    const FuncSig *sg = target_sig(c, K);
    emit_linef(c, depth, "(call $user_%d_da1\n", K->func_idx);
    emit_line(c, depth + 1, "(ref.cast (ref $LuaClosure)\n");
    emit_expr(c, e->as.call.callee, depth + 2);
    emit_line(c, depth + 1, ")\n");
    emit_typed_args(c, e, sg, depth + 1);
    emit_line(c, depth, ")\n");
}

/* Single-result calls with at most this many arguments (a method call's
 * receiver included) use the closure's $fast entry ($LuaFn1). */
#define FAST_MAX_ARGS 4

/* Whether `fn` gets a $user_N_f body: the specializer is on and its named
 * parameters fit the fast entry's argument registers. Other closures use
 * $fast_adapter. */
int fn_has_fast_entry(const CG *c, const LuaFunc *fn) {
    return c->opt_int && fn->n_params <= FAST_MAX_ARGS;
}

/* A call's or method call's own argument list (a method call's receiver is
 * not part of it). */
static void call_arg_list(const Expr *e, Expr *const **args, size_t *n) {
    if (e->kind == EXPR_METHOD_CALL) {
        *args = e->as.method_call.args;
        *n = e->as.method_call.nargs;
    } else {
        *args = e->as.call.args;
        *n = e->as.call.nargs;
    }
}

/* The number of fast-entry arguments of a call or method call (the receiver
 * counts), or -1 when it can't use the fast entry: too many, or a trailing
 * multi-value argument whose length is only known at run time. */
int fast_call_nargs(const CG *c, const Expr *e) {
    if (!c->opt_int || (e->kind != EXPR_CALL && e->kind != EXPR_METHOD_CALL)) return -1;
    Expr *const *args;
    size_t na;
    call_arg_list(e, &args, &na);
    size_t n = na + (e->kind == EXPR_METHOD_CALL);
    if (n > FAST_MAX_ARGS) return -1;
    if (na > 0 && is_multival_tail(args[na - 1])) return -1;
    return (int)n;
}

/* Build a (ref $ArgArr) from a sequence of argument expressions, splicing
 * the trailing expression's full multi-value result if it is a call or `...`. */
void emit_args_array(CG *c, Expr **args, size_t nargs, int depth) {
    if (nargs == 0) {
        emit_line(c, depth, "(global.get $g_empty_args)\n");
        return;
    }
    int last_mv = is_multival_tail(args[nargs - 1]);
    if (!last_mv) {
        emit_linef(c, depth, "(array.new_fixed $ArgArr %zu\n", nargs);
        for (size_t i = 0; i < nargs; i++) emit_expr(c, args[i], depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    size_t singles = nargs - 1;
    emit_line(c, depth, "(call $merge_args\n");
    if (singles == 0) {
        emit_line(c, depth + 1, "(global.get $g_empty_args)\n");
    } else {
        emit_linef(c, depth + 1, "(array.new_fixed $ArgArr %zu\n", singles);
        for (size_t i = 0; i < singles; i++) emit_expr(c, args[i], depth + 2);
        emit_line(c, depth + 1, ")\n");
    }
    emit_multival_array(c, args[nargs - 1], depth + 1);
    emit_line(c, depth, ")\n");
}

/* A method call `obj:m(...)` evaluates obj once, into $tmp_any, where the
 * method lookup and the argument list read it. Both read it before any
 * argument is evaluated, so an argument that is itself a method call may
 * reuse $tmp_any. */
static void emit_park_receiver(CG *c, const Expr *e, int depth) {
    emit_line(c, depth, "(local.set $tmp_any\n");
    emit_expr(c, e->as.method_call.recv, depth + 1);
    emit_line(c, depth, ")\n");
}

/* Look up `obj:m` via $lua_index_sk (constant string key; routes strings
 * through the string library). The receiver must already be parked in
 * $tmp_any. Emits, at `depth`:
 *   (call $lua_index_sk (local.get $tmp_any) <hoisted method name> (i32.const line))
 * Shared by the value and tail-call method forms. */
static void emit_method_lookup(CG *c, const char *method, size_t method_len, int line,
                               int depth) {
    emit_indent(c, depth);
    /* $lua_index_sk reads the key's precomputed hash, so it is only for hoisted
     * constants; a name too long to hoist takes the generic lookup. With the
     * specializer on, a hoisted name gets a method inline cache. */
    int mic = c->opt_int && method_len <= KSTR_MAX ? c->n_mics++ : -1;
    wat_append(c->w, mic >= 0                 ? "(call $lua_method_ic\n"
                     : method_len <= KSTR_MAX ? "(call $lua_index_sk\n"
                                              : "(call $lua_index\n");
    emit_line(c, depth + 1, "(local.get $tmp_any)\n");
    emit_string_literal(c, method, method_len, depth + 1);
    emit_linef(c, depth + 1, "(i32.const %d)\n", line);
    if (mic >= 0) {
        emit_linef(c, depth + 1, "(global.get $mic_%d)\n", mic);
    }
    emit_line(c, depth, ")\n");
}

/* The value a call calls: a call's callee expression, or a method call's
 * method looked up on the parked receiver. */
static void emit_callee(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL)
        emit_method_lookup(c, e->as.method_call.method, e->as.method_call.method_len, e->line, depth);
    else emit_expr(c, e->as.call.callee, depth);
}

/* Emit the method-call argument array [recv] ++ method-args, at `depth`:
 *   (call $merge_args (array.new_fixed $ArgArr 1 (local.get $tmp_any)) <args>)
 * The receiver must already be parked in $tmp_any. Shared by the value and
 * tail-call method forms. */
static void emit_method_args_array(CG *c, const Expr *e, int depth) {
    size_t mna = e->as.method_call.nargs;
    int has_mv = mna > 0 && is_multival_tail(e->as.method_call.args[mna - 1]);
    if (!has_mv) {
        /* Fixed arity: build [recv, args...] in one array.new_fixed. The
         * receiver is read from $tmp_any first (operand order), so an argument
         * that is itself a method call may reuse $tmp_any safely. */
        emit_linef(c, depth, "(array.new_fixed $ArgArr %zu\n", mna + 1);
        emit_line(c, depth + 1, "(local.get $tmp_any)\n");
        for (size_t i = 0; i < mna; i++) emit_expr(c, e->as.method_call.args[i], depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    emit_line(c, depth, "(call $merge_args\n");
    emit_line(c, depth + 1, "(array.new_fixed $ArgArr 1 (local.get $tmp_any))\n");
    emit_args_array(c, e->as.method_call.args, mna, depth + 1);
    emit_line(c, depth, ")\n");
}

/* A call's arguments as an $ArgArr (a method call's with its receiver first). */
static void emit_call_args_array(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL) emit_method_args_array(c, e, depth);
    else emit_args_array(c, e->as.call.args, e->as.call.nargs, depth);
}

/* A call returning (ref $ArgArr) — the full multi-value result. */
void emit_call_array(CG *c, const Expr *e, int depth) {
    const LuaFunc *dt = direct_call_target(c, e);
    if (dt && direct_args_typed_ok(c, e, dt)) {
        /* Direct-args call: pass the closure + (typed) args to $user_N_da,
         * no $ArgArr allocation. Returns the result array like $lua_call_any.
         * (Frame push/pop is skipped — a known function needs no __call walk;
         * error positions inside it fall back to the caller's frame, matching
         * the project's "error position not tracked" stance.) */
        emit_linef(c, depth, "(call $user_%d_da\n", dt->func_idx);
        emit_line(c, depth + 1, "(ref.cast (ref $LuaClosure)\n");
        emit_expr(c, e->as.call.callee, depth + 2);
        emit_line(c, depth + 1, ")\n");
        emit_typed_args(c, e, target_sig(c, dt), depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    if (e->kind == EXPR_METHOD_CALL) emit_park_receiver(c, e, depth);
    emit_line(c, depth, "(call $lua_call_any\n");
    emit_callee(c, e, depth + 1);
    emit_call_args_array(c, e, depth + 1);
    emit_linef(c, depth + 1, "(i32.const %d)\n", e->line);
    emit_line(c, depth, ")\n");
}

/* A single-result call through $lua_call1 (the callee's $fast entry): the
 * callee, then the arguments in order — a method call's receiver first —
 * nil-padded to four, plus the count. Callers check fast_call_nargs first. */
void emit_fast_call(CG *c, const Expr *e, int depth) {
    int n = fast_call_nargs(c, e);
    Expr *const *args;
    size_t na;
    call_arg_list(e, &args, &na);
    if (e->kind == EXPR_METHOD_CALL) emit_park_receiver(c, e, depth);
    emit_line(c, depth, "(call $lua_call1\n");
    emit_callee(c, e, depth + 1);
    if (e->kind == EXPR_METHOD_CALL) emit_line(c, depth + 1, "(local.get $tmp_any)\n");
    for (size_t i = 0; i < na; i++) emit_expr(c, args[i], depth + 1);
    for (int i = n; i < FAST_MAX_ARGS; i++) emit_line(c, depth + 1, "(ref.null any)\n");
    emit_linef(c, depth + 1, "(i32.const %d) (i32.const %d)\n", n, e->line);
    emit_line(c, depth, ")\n");
}

/* A call in single-value context: the direct single-result entry, the fast
 * entry, or the full call with its first result taken. */
static void emit_call(CG *c, const Expr *e, int depth) {
    const LuaFunc *dt = direct_call_target(c, e);
    if (dt && direct_args_typed_ok(c, e, dt)) {
        /* Single-value direct call: invoke the $user_N_da1 entry, which returns
         * one value directly — no $ArgArr and no $args_first. A numeric-returning
         * call is routed through emit_int/float_expr upstream (expr_is_int/float),
         * so when we get here ret_ty is ANY and $user_N_da1 yields one anyref. */
        emit_typed_direct_call1(c, e, dt, depth);
        return;
    }
    if (fast_call_nargs(c, e) >= 0) {
        emit_fast_call(c, e, depth);
        return;
    }
    emit_line(c, depth, "(call $args_first\n");
    emit_call_array(c, e, depth + 1);
    emit_line(c, depth, ")\n");
}

/* ----- tail calls -----
 * `return f(args)` / `return obj:m(args)` lowers to a return_call_ref, so
 * deep recursion doesn't grow the wasm call stack. */

/* Evaluate a tail call's callee into $tmp_callee — not $tmp_any, which a
 * method call among the arguments reuses for its receiver while the
 * arguments are evaluated. */
static void emit_tail_callee(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL) emit_park_receiver(c, e, depth);
    emit_line(c, depth, "(local.set $tmp_callee\n");
    emit_callee(c, e, depth + 1);
    emit_line(c, depth, ")\n");
}

/* The end of a tail call whose callee is in $tmp_callee. A closure takes over
 * the caller's frame — its line becomes this call site's, so error() and
 * tracebacks see it — and is entered with `entry_call`, a return_call_ref.
 * Anything else (a __call table, a non-callable) takes `slow_call`, an
 * ordinary call that walks __call or raises: losing TCO for a metamethod hop
 * is fine. */
static void emit_tail_dispatch(CG *c, int line, const char *entry_call, const char *slow_call, int depth) {
    emit_line(c, depth, "(if (ref.test (ref $LuaClosure) (local.get $tmp_callee))\n");
    emit_line(c, depth + 1, "(then\n");
    emit_line(c, depth + 2, "(local.set $tmp_clo (ref.cast (ref $LuaClosure) (local.get $tmp_callee)))\n");
    emit_linef(c, depth + 2,
               "(call $replace_top_call_frame (i32.const %d) "
               "(struct.get $LuaClosure $weight (ref.as_non_null (local.get $tmp_clo))))\n",
               line);
    emit_linef(c, depth + 2, "%s))\n", entry_call);
    emit_linef(c, depth, "(return %s)\n", slow_call);
}

/* A tail call through the callee's $code: the arguments as an array. */
void emit_tail_call(CG *c, const Expr *e, int depth) {
    emit_tail_callee(c, e, depth);
    emit_line(c, depth, "(local.set $tmp_args\n");
    emit_call_args_array(c, e, depth + 1);
    emit_line(c, depth, ")\n");
    char slow[160];
    snprintf(slow, sizeof slow,
             "(call $lua_call_any (local.get $tmp_callee) (ref.as_non_null (local.get $tmp_args)) (i32.const %d))",
             e->line);
    emit_tail_dispatch(c, e->line,
                       "(return_call_ref $LuaFn (ref.as_non_null (local.get $tmp_clo)) "
                       "(ref.as_non_null (local.get $tmp_args)) "
                       "(struct.get $LuaClosure $code (ref.as_non_null (local.get $tmp_clo))))",
                       slow, depth);
}

/* A tail call inside a $user_N_f body that fits the fast entry: through the
 * callee's $fast, the arguments evaluated in order into $ta0..$ta3 (a method
 * call's receiver first). */
void emit_fast_tail_call(CG *c, const Expr *e, int depth) {
    int n = fast_call_nargs(c, e), k = 0;
    Expr *const *args;
    size_t na;
    call_arg_list(e, &args, &na);
    emit_tail_callee(c, e, depth);
    if (e->kind == EXPR_METHOD_CALL) emit_line(c, depth, "(local.set $ta0 (local.get $tmp_any))\n"), k = 1;
    for (size_t i = 0; i < na; i++, k++) {
        emit_linef(c, depth, "(local.set $ta%d\n", k);
        emit_expr(c, args[i], depth + 1);
        emit_line(c, depth, ")\n");
    }
    char regs[160], entry[384], slow[256];
    int off = 0;
    for (int i = 0; i < FAST_MAX_ARGS; i++)
        off += snprintf(regs + off, sizeof regs - (size_t)off, i < n ? " (local.get $ta%d)" : " (ref.null any)", i);
    snprintf(entry, sizeof entry,
             "(return_call_ref $LuaFn1 (ref.as_non_null (local.get $tmp_clo))%s (i32.const %d) "
             "(struct.get $LuaClosure $fast (ref.as_non_null (local.get $tmp_clo))))",
             regs, n);
    snprintf(slow, sizeof slow, "(call $lua_call1 (local.get $tmp_callee)%s (i32.const %d) (i32.const %d))", regs, n,
             e->line);
    emit_tail_dispatch(c, e->line, entry, slow, depth);
}

/* ----- function expression: build a closure -----
 * The upvalue array collects the parent's boxes per the function's
 * upvalue table.
 */
void emit_function_expr(CG *c, const LuaFunc *fn, int depth) {
    emit_line(c, depth, "(struct.new $LuaClosure\n");
    emit_linef(c, depth + 1, "(ref.func $user_%d)\n", fn->func_idx);
    if (fn->n_upvalues == 0) {
        emit_line(c, depth + 1, "(global.get $g_empty_upvals)\n");
    } else {
        emit_linef(c, depth + 1, "(array.new_fixed $UpvalArr %d\n", fn->n_upvalues);
        for (int i = 0; i < fn->n_upvalues; i++) {
            UpvalueRef *u = &fn->upvalues[i];
            VarKind k = (u->src == UPVAL_FROM_LOCAL) ? VAR_LOCAL : VAR_UPVAL;
            emit_box_ref(c, k, u->idx, depth + 2);
        }
        emit_line(c, depth + 1, ")\n");
    }
    emit_linef(c, depth + 1, "(i32.const %d)\n", fn_frame_weight(c, fn));
    emit_indent(c, depth + 1);
    if (fn_has_fast_entry(c, fn)) wat_appendf(c->w, "(ref.func $user_%d_f)\n", fn->func_idx);
    else wat_append(c->w, "(ref.func $fast_adapter)\n");
    emit_line(c, depth, ")\n");
}

/* ----- table operations ----- */
static void emit_index_expr(CG *c, const Expr *e, int depth) {
    /* `t[k]`. Use the runtime $lua_index helper instead of an inline
     * (ref.cast (ref $LuaTable) …) so that strings transparently route
     * through the string library and other-typed receivers throw a
     * Lua-shaped error with a source line. For an int-typed key, the
     * $lua_index_ik fast path takes the raw i64 (no make_int / $as_arr_key)
     * and hits the array part directly. */
    if (e->as.index.key->kind == EXPR_STRING && e->as.index.key->as.s.len <= KSTR_MAX) {
        /* `t.name` / `t["lit"]`: the hoisted key global goes straight to the
         * hash part (strings never live in the array part), through the
         * site's inline cache when the specializer is on. */
        char icb[48];
        const char *ic = ic_new(c, icb, sizeof icb);
        emit_line(c, depth, ic ? "(call $lua_index_ic\n" : "(call $lua_index_sk\n");
        emit_expr(c, e->as.index.table, depth + 1);
        emit_string_literal(c, e->as.index.key->as.s.bytes, e->as.index.key->as.s.len, depth + 1);
        emit_linef(c, depth + 1, "(i32.const %d)%s%s\n", e->line, ic ? " " : "", ic ? ic : "");
        emit_line(c, depth, ")\n");
        return;
    }
    if (e->as.index.key->kind == EXPR_VAR && e->as.index.key->as.var.kind == VAR_LOCAL &&
        slot_is_maybe(c, e->as.index.key->as.var.idx)) {
        /* Maybe-typed key: the cell goes over unboxed; an int takes the
         * array fast path, anything else boxes on the slow path. */
        MCell k = mcell_slot(e->as.index.key->as.var.idx);
        emit_line(c, depth, "(call $lua_index_mk\n");
        emit_expr(c, e->as.index.table, depth + 1);
        emit_linef(c, depth + 1, "%s %s %s %s (i32.const %d)\n", k.t, k.i, k.f, k.b, e->line);
        emit_line(c, depth, ")\n");
        return;
    }
    if (c->opt_int && expr_is_int(c, e->as.index.key)) {
        emit_line(c, depth, "(call $lua_index_ik\n");
        emit_expr(c, e->as.index.table, depth + 1);
        emit_int_expr(c, e->as.index.key, depth + 1);
        emit_linef(c, depth + 1, "(i32.const %d)\n", e->line);
        emit_line(c, depth, ")\n");
        return;
    }
    emit_line(c, depth, "(call $lua_index\n");
    emit_expr(c, e->as.index.table, depth + 1);
    emit_expr(c, e->as.index.key, depth + 1);
    emit_linef(c, depth + 1, "(i32.const %d)\n", e->line);
    emit_line(c, depth, ")\n");
}

/* Largest record a constructor builds on a cached shape; matches the
 * runtime's $shape_share_max (a table with more keys is a dictionary). */
#define CTOR_SHAPE_MAX 32

/* The number of `name = v` fields of a constructor that can be built on a
 * cached shape: every non-positional key a hoistable constant string, all
 * distinct, at most CTOR_SHAPE_MAX of them. 0 when there are none or the
 * constructor doesn't qualify (computed keys keep the incremental path). */
static int ctor_shape_fields(const CG *c, const Expr *e) {
    if (!c->opt_int) return 0;
    int n = e->as.table_ctor.n_entries, k = 0;
    for (int i = 0; i < n; i++) {
        const TableEntry *ent = &e->as.table_ctor.entries[i];
        if (ent->kind == TENT_POSITIONAL) continue;
        if (ent->key->kind != EXPR_STRING || ent->key->as.s.len > KSTR_MAX) return 0;
        for (int j = 0; j < i; j++) {
            const TableEntry *o = &e->as.table_ctor.entries[j];
            if (o->kind != TENT_POSITIONAL && o->key->as.s.len == ent->key->as.s.len &&
                memcmp(o->key->as.s.bytes, ent->key->as.s.bytes, ent->key->as.s.len) == 0)
                return 0;
        }
        k++;
    }
    return k <= CTOR_SHAPE_MAX ? k : 0;
}

static void emit_table_ctor(CG *c, const Expr *e, int depth) {
    int n = e->as.table_ctor.n_entries;
    /* Wrap in a block so the constructor appears as a single folded
     * expression from outside (works inside array.new_fixed arg lists,
     * function calls, etc.) but uses stack-form internally to keep the
     * in-progress table on the operand stack across entries. */
    emit_line(c, depth, "(block (result anyref)\n");
    int nshape = ctor_shape_fields(c, e);
    if (nshape > 0) {
        /* Its fields' final layout is known: start from the site's cached
         * shape (built on first use) and fill values in by position. */
        int site = c->n_ctor_shapes++;
        emit_linef(c, depth + 1, "(if (ref.is_null (global.get $cshape_%d))\n", site);
        emit_linef(c, depth + 2, "(then (global.set $cshape_%d (call $shape_for_keys (array.new_fixed $TArr %d", site,
                   nshape);
        for (int i = 0; i < n; i++) {
            const TableEntry *ent = &e->as.table_ctor.entries[i];
            if (ent->kind == TENT_POSITIONAL) continue;
            char eb[160];
            wat_appendf(c->w, " %s", kstr_expr(c, ent->key->as.s.bytes, ent->key->as.s.len, eb, sizeof eb));
        }
        wat_append(c->w, ")))))\n");
        emit_linef(c, depth + 1, "(call $tab_new_shaped (ref.as_non_null (global.get $cshape_%d)))\n", site);
    } else {
        emit_line(c, depth + 1, "(call $tab_new)\n");
    }
    int field_pos = 0;
    int pos_idx = 1;
    /* If the final entry is positional AND a multi-value tail (call/vararg),
     * we splice all of its values rather than just taking the first. */
    int splice_last = (n > 0 &&
                       e->as.table_ctor.entries[n - 1].kind == TENT_POSITIONAL &&
                       is_multival_tail(e->as.table_ctor.entries[n - 1].value));
    int last_normal = splice_last ? n - 1 : n;
    for (int i = 0; i < last_normal; i++) {
        TableEntry *ent = &e->as.table_ctor.entries[i];
        emit_line(c, depth + 1, "local.tee $tmp_tab\n");
        emit_line(c, depth + 1, "(ref.as_non_null (local.get $tmp_tab))\n");
        if (ent->kind == TENT_POSITIONAL) {
            /* Raw integer key: straight to the array part, no key boxing. */
            emit_linef(c, depth + 1, "(i64.const %d)\n", pos_idx++);
            emit_expr(c, ent->value, depth + 1);
            emit_line(c, depth + 1, "call $tab_set_ik\n");
            continue;
        }
        if (nshape > 0) {
            /* A field of a shaped constructor: its value goes to its position. */
            int vfloat = expr_is_float(c, ent->value);
            emit_linef(c, depth + 1, "(i32.const %d)\n", field_pos++);
            if (vfloat) emit_float_expr(c, ent->value, depth + 1);
            else emit_expr(c, ent->value, depth + 1);
            emit_line(c, depth + 1, vfloat ? "call $tab_put_pos_f\n" : "call $tab_put_pos\n");
            continue;
        }
        if (ent->key->kind == EXPR_STRING && ent->key->as.s.len <= KSTR_MAX) {
            /* `{name = v}`: hoisted key global + its precomputed hash, straight
             * into the hash part (a fresh table has no metatable). A provably
             * float value goes into the unboxed float storage. */
            char eb[160];
            int vfloat = c->opt_int && expr_is_float(c, ent->value);
            emit_linef(c, depth + 1, "%s\n",
                       kstr_expr(c, ent->key->as.s.bytes, ent->key->as.s.len, eb, sizeof eb));
            emit_linef(c, depth + 1, "(i32.const %d)\n",
                       (int)kstr_hash(ent->key->as.s.bytes, ent->key->as.s.len));
            if (vfloat) emit_float_expr(c, ent->value, depth + 1);
            else emit_expr(c, ent->value, depth + 1);
            emit_line(c, depth + 1, vfloat ? "call $tab_set_f_hash_str\n" : "call $tab_set_hash_str\n");
            continue;
        }
        emit_expr(c, ent->key, depth + 1);
        emit_expr(c, ent->value, depth + 1);
        emit_line(c, depth + 1, "call $tab_set\n");
    }
    if (splice_last) {
        /* (call $tab_append_args (local.tee $tmp_tab) (i32.const pos_idx) <args>) */
        emit_line(c, depth + 1, "local.tee $tmp_tab\n");
        emit_line(c, depth + 1, "(call $tab_append_args\n");
        emit_line(c, depth + 2, "(ref.as_non_null (local.get $tmp_tab))\n");
        emit_linef(c, depth + 2, "(i32.const %d)\n", pos_idx);
        emit_multival_array(c, e->as.table_ctor.entries[n - 1].value, depth + 2);
        emit_line(c, depth + 1, ")\n");
    }
    emit_line(c, depth, ")\n");
}

/* ----- unboxed int / float expression trees ----- */

/* Emit `e` (which must satisfy expr_is_int) as a raw i64 on the wasm stack. */
void emit_int_expr(CG *c, const Expr *e, int depth) {
    if (!c->ok) return;
    switch (e->kind) {
    case EXPR_INT:
        emit_linef(c, depth, "(i64.const %lld)\n", (long long)e->as.i_val);
        return;
    case EXPR_VAR:
        emit_linef(c, depth, "(local.get $L%d)\n", e->as.var.idx);
        return;
    case EXPR_UNOP:
        if (e->as.unop.op == UN_NEG) {
            emit_line(c, depth, "(i64.sub (i64.const 0)\n");
            emit_int_expr(c, e->as.unop.operand, depth + 1);
            emit_line(c, depth, ")\n");
        } else { /* UN_BNOT */
            emit_line(c, depth, "(i64.xor (i64.const -1)\n");
            emit_int_expr(c, e->as.unop.operand, depth + 1);
            emit_line(c, depth, ")\n");
        }
        return;
    case EXPR_BINOP: {
        const char *op = NULL, *fn = NULL;
        switch (e->as.binop.op) {
        case BIN_ADD: op = "i64.add"; break;
        case BIN_SUB: op = "i64.sub"; break;
        case BIN_MUL: op = "i64.mul"; break;
        case BIN_BAND: op = "i64.and"; break;
        case BIN_BOR: op = "i64.or"; break;
        case BIN_BXOR: op = "i64.xor"; break;
        case BIN_FDIV: fn = "$idiv_floor"; break;
        case BIN_MOD: fn = "$imod_floor"; break;
        default: break;
        }
        emit_indent(c, depth);
        if (fn) wat_appendf(c->w, "(call %s\n", fn);
        else wat_appendf(c->w, "(%s\n", op);
        emit_int_expr(c, e->as.binop.lhs, depth + 1);
        emit_int_expr(c, e->as.binop.rhs, depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    case EXPR_CALL:
        /* Guarded by expr_is_int: a direct call to an int-returning function. */
        emit_typed_direct_call1(c, e, direct_call_target(c, e), depth);
        return;
    default:
        cg_error(c, "emit_int_expr on non-integer expression");
    }
}

/* Emit a numeric (int- or float-typed) expression as a raw f64, converting an
 * integer operand with f64.convert_i64_s. */
void emit_num_as_f64(CG *c, const Expr *e, int depth) {
    if (expr_is_float(c, e)) {
        emit_float_expr(c, e, depth);
        return;
    }
    /* must be integer-typed (the only other case expr_is_float admits) */
    emit_line(c, depth, "(f64.convert_i64_s\n");
    emit_int_expr(c, e, depth + 1);
    emit_line(c, depth, ")\n");
}

/* Emit `e` (which must satisfy expr_is_float) as a raw f64 on the wasm stack. */
void emit_float_expr(CG *c, const Expr *e, int depth) {
    if (!c->ok) return;
    switch (e->kind) {
    case EXPR_FLOAT:
        emit_linef(c, depth, "(f64.const %.17g)\n", e->as.f_val);
        return;
    case EXPR_VAR:
        emit_linef(c, depth, "(local.get $L%d)\n", e->as.var.idx);
        return;
    case EXPR_UNOP: /* UN_NEG */
        emit_line(c, depth, "(f64.neg\n");
        emit_num_as_f64(c, e->as.unop.operand, depth + 1);
        emit_line(c, depth, ")\n");
        return;
    case EXPR_BINOP: {
        const char *op = "f64.add";
        switch (e->as.binop.op) {
        case BIN_ADD: op = "f64.add"; break;
        case BIN_SUB: op = "f64.sub"; break;
        case BIN_MUL: op = "f64.mul"; break;
        case BIN_DIV: op = "f64.div"; break;
        default: break;
        }
        emit_linef(c, depth, "(%s\n", op);
        emit_num_as_f64(c, e->as.binop.lhs, depth + 1);
        emit_num_as_f64(c, e->as.binop.rhs, depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    case EXPR_CALL:
        /* Guarded by expr_is_float: a direct call to a float-returning function. */
        emit_typed_direct_call1(c, e, direct_call_target(c, e), depth);
        return;
    default:
        cg_error(c, "emit_float_expr on non-float expression");
    }
}

/* ----- main expression dispatch ----- */
void emit_expr(CG *c, const Expr *e, int depth) {
    if (!c->ok) return;
    /* Integer-specialized value used in a Lua-value (anyref) context: emit the
     * unboxed i64 and box it. EXPR_INT keeps its existing path. */
    if (c->opt_int && e->kind != EXPR_INT && expr_is_int(c, e)) {
        emit_line(c, depth, "(call $make_int\n");
        emit_int_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    if (c->opt_int && e->kind != EXPR_FLOAT && expr_is_float(c, e)) {
        emit_line(c, depth, "(call $make_float\n");
        emit_float_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    switch (e->kind) {
    case EXPR_NIL:
        emit_line(c, depth, "(ref.null any)\n");
        break;
    case EXPR_TRUE:
        emit_line(c, depth, "(global.get $g_true)\n");
        break;
    case EXPR_FALSE:
        emit_line(c, depth, "(global.get $g_false)\n");
        break;
    case EXPR_INT: emit_int_literal(c, e->as.i_val, depth); break;
    case EXPR_FLOAT: emit_float_literal(c, e->as.f_val, depth); break;
    case EXPR_STRING: emit_string_literal(c, e->as.s.bytes, e->as.s.len, depth); break;
    case EXPR_VAR: emit_var_read(c, e->as.var.kind, e->as.var.idx, depth); break;
    case EXPR_CALL: emit_call(c, e, depth); break;
    case EXPR_BINOP: emit_binop(c, e, depth); break;
    case EXPR_UNOP: emit_unop(c, e, depth); break;
    case EXPR_FUNCTION: emit_function_expr(c, e->as.func_expr.func, depth); break;
    case EXPR_INDEX: emit_index_expr(c, e, depth); break;
    case EXPR_TABLE: emit_table_ctor(c, e, depth); break;
    case EXPR_METHOD_CALL: {
        /* Single-value context: the fast entry when the call fits it, else
         * the full call wrapped in $args_first. */
        if (fast_call_nargs(c, e) >= 0) {
            emit_fast_call(c, e, depth);
            break;
        }
        emit_line(c, depth, "(call $args_first\n");
        emit_call_array(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        break;
    }
    case EXPR_VARARG:
        emit_line(c, depth, "(call $args_first (local.get $varargs))\n");
        break;
    }
}

/* Emit `(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const idx))`
 * as a standalone indented line — the i-th value of the call/vararg result
 * currently parked in $tmp_args. */
void emit_args_at(CG *c, int idx, int depth) {
    emit_linef(c, depth, "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const %d))\n",
               idx);
}
