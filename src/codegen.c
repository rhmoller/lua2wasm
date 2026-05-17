#include "codegen.h"
#include "builtins.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================
 * Codegen v3a.
 *
 * Value representation: every Lua value is `anyref`.
 *   nil      -> (ref.null any)
 *   false    -> global $g_false   : (ref $LuaBool) struct{ i32 0 }
 *   true     -> global $g_true    : (ref $LuaBool) struct{ i32 1 }
 *   int      -> i31ref (small) | (struct.new $LuaInt i64) (overflow)
 *   float    -> (struct.new $LuaFloat f64)
 *   string   -> (struct.new $LuaString (array i8))
 *   function -> (ref $LuaClosure)
 *
 * Closure runtime:
 *   $Box       = struct { mut anyref v }     -- shared mutable cell
 *   $ArgArr    = array (mut anyref)
 *   $UpvalArr  = array (mut (ref $Box))
 *   $LuaFn     = func ((ref $LuaClosure) (ref $ArgArr)) -> anyref
 *   $LuaClosure = struct { (ref $LuaFn) code, (ref $UpvalArr) upvals }
 *
 * All locals (and parameters) are stored in $Box cells so they can be
 * captured by inner closures and remain mutable. Boxing is uniform; we
 * leave any "is this local actually captured?" escape analysis as a
 * later optimization.
 *
 * Each Lua function in source becomes a top-level wasm function named
 * `$user_N` (N = LuaFunc.func_idx). The implicit chunk becomes `$main`,
 * which has no closure/args parameters and no return value.
 * ============================================================ */

/* ----- string-literal pool ----- */
typedef struct {
    char *bytes;
    size_t used;
    size_t cap;
} StrPool;

typedef struct {
    size_t offset;
    size_t len;
} StrRef;

static StrRef strpool_add(StrPool *p, const char *bytes, size_t len) {
    if (p->used + len > p->cap) {
        size_t new_cap = p->cap ? p->cap : 64;
        while (p->used + len > new_cap) new_cap *= 2;
        p->bytes = realloc(p->bytes, new_cap);
        p->cap = new_cap;
    }
    StrRef r = { .offset = p->used, .len = len };
    memcpy(p->bytes + p->used, bytes, len);
    p->used += len;
    return r;
}

/* ----- codegen context ----- */
typedef struct {
    WatBuilder *w;
    StrPool strs;
    int next_label;
    int in_main;            /* 1 while emitting $main body, 0 inside user fn */
    int break_labels[16];   /* break targets for nested while/for/repeat */
    int break_depth;
    char err[256];
    int ok;
} CG;

static void cg_error(CG *c, const char *msg) {
    if (!c->ok) return;
    c->ok = 0;
    snprintf(c->err, sizeof(c->err), "codegen: %s", msg);
}

static void emit_indent(CG *c, int depth) {
    for (int i = 0; i < depth; i++) wat_append(c->w, "  ");
}

static int i31_fits(int64_t v) {
    return v >= -(int64_t)0x40000000 && v < (int64_t)0x40000000;
}

/* ----- forward decls ----- */
static void emit_expr(CG *c, const Expr *e, int depth);
static void emit_block(CG *c, const Block *b, int depth);
static void emit_stmt(CG *c, const Stmt *s, int depth);

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
    emit_indent(c, depth);
    wat_appendf(c->w, "(struct.new $LuaFloat (f64.const %.17g))\n", v);
}

static void emit_string_literal(CG *c, const char *bytes, size_t len, int depth) {
    StrRef r = strpool_add(&c->strs, bytes, len);
    emit_indent(c, depth);
    wat_appendf(c->w,
        "(struct.new $LuaString "
        "(array.new_data $LuaArr $str_data (i32.const %zu) (i32.const %zu)))\n",
        r.offset, r.len);
}

/* ----- variable read / write -----
 * VAR_UPVAL is only emitted inside user functions (parser guarantees this:
 * main has no upvalues to capture).
 */
static void emit_var_read(CG *c, VarKind kind, int idx, int depth) {
    emit_indent(c, depth);
    switch (kind) {
        case VAR_LOCAL:
            wat_appendf(c->w, "(struct.get $Box $v (local.get $L%d))\n", idx);
            break;
        case VAR_UPVAL:
            wat_appendf(c->w,
                "(struct.get $Box $v (array.get $UpvalArr "
                "(struct.get $LuaClosure $upvals (local.get $closure)) "
                "(i32.const %d)))\n", idx);
            break;
        case VAR_BUILTIN:
            wat_appendf(c->w, "(global.get $g_builtin_%s)\n", builtin_name(idx));
            break;
        case VAR_GLOBAL:
            wat_appendf(c->w, "(global.get $g_user_%d)\n", idx);
            break;
    }
}

/* Emit code that pushes the (ref $Box) for the named binding (not its value).
 * Used for upvalue capture into a child closure. Globals and builtins don't
 * have boxes. */
static void emit_box_ref(CG *c, VarKind kind, int idx, int depth) {
    emit_indent(c, depth);
    switch (kind) {
        case VAR_LOCAL:
            wat_appendf(c->w, "(local.get $L%d)\n", idx);
            break;
        case VAR_UPVAL:
            wat_appendf(c->w,
                "(array.get $UpvalArr "
                "(struct.get $LuaClosure $upvals (local.get $closure)) "
                "(i32.const %d))\n", idx);
            break;
        case VAR_BUILTIN:
        case VAR_GLOBAL:
            cg_error(c, "cannot take a box reference to a builtin/global");
            break;
    }
}

/* Open the "store to this target" expression. The caller must then emit the
 * value expression as a child, then call emit_target_close(). */
static void emit_target_open(CG *c, const AssignTarget *t, int depth) {
    if (t->kind == TGT_VAR) {
        switch (t->as.var.kind) {
            case VAR_LOCAL:
            case VAR_UPVAL:
                emit_indent(c, depth); wat_append(c->w, "(struct.set $Box $v\n");
                emit_box_ref(c, t->as.var.kind, t->as.var.idx, depth + 1);
                break;
            case VAR_GLOBAL:
                emit_indent(c, depth);
                wat_appendf(c->w, "(global.set $g_user_%d\n", t->as.var.idx);
                break;
            case VAR_BUILTIN:
                cg_error(c, "cannot assign to builtin print");
                break;
        }
    } else {
        emit_indent(c, depth); wat_append(c->w, "(call $tab_set\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(ref.cast (ref $LuaTable)\n");
        emit_expr(c, t->as.index.table, depth + 2);
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
        emit_expr(c, t->as.index.key, depth + 1);
    }
}
static void emit_target_close(CG *c, const AssignTarget *t, int depth) {
    (void)t;
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* ----- binary / unary ops ----- */
static const char *binop_helper(BinOp op) {
    switch (op) {
        case BIN_ADD:    return "$lua_add";
        case BIN_SUB:    return "$lua_sub";
        case BIN_MUL:    return "$lua_mul";
        case BIN_DIV:    return "$lua_div";
        case BIN_FDIV:   return "$lua_fdiv";
        case BIN_MOD:    return "$lua_mod";
        case BIN_POW:    return "$lua_pow";
        case BIN_CONCAT: return "$lua_concat";
        case BIN_EQ:     return "$lua_eq";
        case BIN_NEQ:    return "$lua_neq";
        case BIN_LT:     return "$lua_lt";
        case BIN_LE:     return "$lua_le";
        case BIN_GT:     return "$lua_gt";
        case BIN_GE:     return "$lua_ge";
        default:         return "$lua_add";
    }
}

static void emit_binop(CG *c, const Expr *e, int depth) {
    BinOp op = e->as.binop.op;
    if (op == BIN_AND || op == BIN_OR) {
        int label = c->next_label++;
        emit_indent(c, depth);
        wat_appendf(c->w, "(block $sc_%d (result anyref)\n", label);

        emit_expr(c, e->as.binop.lhs, depth + 1);
        emit_indent(c, depth + 1); wat_append(c->w, "local.set $tmp_any\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(call $lua_truthy (local.get $tmp_any))\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(if (then\n");
        if (op == BIN_AND) {
            emit_expr(c, e->as.binop.rhs, depth + 2);
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $sc_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            emit_indent(c, depth + 1); wat_append(c->w, "local.get $tmp_any\n");
        } else {
            emit_indent(c, depth + 2); wat_append(c->w, "local.get $tmp_any\n");
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $sc_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            emit_expr(c, e->as.binop.rhs, depth + 1);
        }
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    emit_expr(c, e->as.binop.lhs, depth);
    emit_expr(c, e->as.binop.rhs, depth);
    emit_indent(c, depth);
    wat_appendf(c->w, "(call %s)\n", binop_helper(op));
}

static void emit_unop(CG *c, const Expr *e, int depth) {
    emit_expr(c, e->as.unop.operand, depth);
    emit_indent(c, depth);
    switch (e->as.unop.op) {
        case UN_NEG: wat_append(c->w, "(call $lua_neg)\n"); break;
        case UN_NOT: wat_append(c->w, "(call $lua_not)\n"); break;
        case UN_LEN: wat_append(c->w, "(call $lua_len)\n"); break;
    }
}

/* Emit a call returning (ref $ArgArr) — the full multi-value result. */
static void emit_call_array(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL) {
        /* obj:m(args). Evaluate receiver once into $tmp_any, look up the
         * method via tab_get, then call with receiver prepended. */
        StrRef sr = strpool_add(&c->strs, e->as.method_call.method, e->as.method_call.method_len);
        emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_any\n");
        emit_expr(c, e->as.method_call.recv, depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        emit_indent(c, depth); wat_append(c->w, "(call $lua_call\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(ref.cast (ref $LuaClosure)\n");
        emit_indent(c, depth + 2); wat_append(c->w, "(call $tab_get\n");
        emit_indent(c, depth + 3); wat_append(c->w, "(ref.cast (ref $LuaTable) (local.get $tmp_any))\n");
        emit_indent(c, depth + 3);
        wat_appendf(c->w,
            "(struct.new $LuaString (array.new_data $LuaArr $str_data "
            "(i32.const %zu) (i32.const %zu)))\n", sr.offset, sr.len);
        emit_indent(c, depth + 2); wat_append(c->w, ")\n");
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
        emit_indent(c, depth + 1);
        wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", e->as.method_call.nargs + 1);
        emit_indent(c, depth + 2); wat_append(c->w, "(local.get $tmp_any)\n");
        for (size_t i = 0; i < e->as.method_call.nargs; i++) {
            emit_expr(c, e->as.method_call.args[i], depth + 2);
        }
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    emit_indent(c, depth); wat_append(c->w, "(call $lua_call\n");
    emit_indent(c, depth + 1); wat_append(c->w, "(ref.cast (ref $LuaClosure)\n");
    emit_expr(c, e->as.call.callee, depth + 2);
    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    emit_indent(c, depth + 1);
    if (e->as.call.nargs == 0) {
        wat_append(c->w, "(array.new_fixed $ArgArr 0)\n");
    } else {
        wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", e->as.call.nargs);
        for (size_t i = 0; i < e->as.call.nargs; i++) {
            emit_expr(c, e->as.call.args[i], depth + 2);
        }
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    }
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* In expression context we want a single anyref; wrap with $args_first. */
static void emit_call(CG *c, const Expr *e, int depth) {
    emit_indent(c, depth); wat_append(c->w, "(call $args_first\n");
    emit_call_array(c, e, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* Tail call: `return f(args)` lowers to a return_call_ref so deep
 * recursion doesn't grow the wasm call stack. We store the casted
 * closure in $tmp_clo so its funcref and the closure itself can both
 * be supplied without re-evaluating the callee expression. */
static void emit_tail_call(CG *c, const Expr *e, int depth) {
    /* Eval callee once → $tmp_clo. */
    emit_expr(c, e->as.call.callee, depth);
    emit_indent(c, depth); wat_append(c->w, "(ref.cast (ref $LuaClosure))\n");
    emit_indent(c, depth); wat_append(c->w, "local.set $tmp_clo\n");
    /* return_call_ref $LuaFn closure args funcref */
    emit_indent(c, depth); wat_append(c->w, "(return_call_ref $LuaFn\n");
    emit_indent(c, depth + 1);
    wat_append(c->w, "(ref.as_non_null (local.get $tmp_clo))\n");
    /* args */
    emit_indent(c, depth + 1);
    if (e->as.call.nargs == 0) {
        wat_append(c->w, "(global.get $g_empty_args)\n");
    } else {
        wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", e->as.call.nargs);
        for (size_t i = 0; i < e->as.call.nargs; i++) {
            emit_expr(c, e->as.call.args[i], depth + 2);
        }
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    }
    /* funcref */
    emit_indent(c, depth + 1);
    wat_append(c->w, "(struct.get $LuaClosure $code "
                     "(ref.as_non_null (local.get $tmp_clo)))\n");
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* ----- function expression: build a closure -----
 * The upvalue array collects the parent's boxes per the function's
 * upvalue table.
 */
static void emit_function_expr(CG *c, const LuaFunc *fn, int depth) {
    emit_indent(c, depth);
    wat_append(c->w, "(struct.new $LuaClosure\n");
    emit_indent(c, depth + 1);
    wat_appendf(c->w, "(ref.func $user_%d)\n", fn->func_idx);
    if (fn->n_upvalues == 0) {
        emit_indent(c, depth + 1);
        wat_append(c->w, "(global.get $g_empty_upvals)\n");
    } else {
        emit_indent(c, depth + 1);
        wat_appendf(c->w, "(array.new_fixed $UpvalArr %d\n", fn->n_upvalues);
        for (int i = 0; i < fn->n_upvalues; i++) {
            UpvalueRef *u = &fn->upvalues[i];
            VarKind k = (u->src == UPVAL_FROM_LOCAL) ? VAR_LOCAL : VAR_UPVAL;
            emit_box_ref(c, k, u->idx, depth + 2);
        }
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    }
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* ----- table operations ----- */
static void emit_index_expr(CG *c, const Expr *e, int depth) {
    emit_indent(c, depth); wat_append(c->w, "(call $tab_get\n");
    emit_indent(c, depth + 1); wat_append(c->w, "(ref.cast (ref $LuaTable)\n");
    emit_expr(c, e->as.index.table, depth + 2);
    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    emit_expr(c, e->as.index.key, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

static void emit_table_ctor(CG *c, const Expr *e, int depth) {
    int n = e->as.table_ctor.n_entries;
    /* Wrap in a block so the constructor appears as a single folded
     * expression from outside (works inside array.new_fixed arg lists,
     * function calls, etc.) but uses stack-form internally to keep the
     * in-progress table on the operand stack across entries. */
    emit_indent(c, depth); wat_append(c->w, "(block (result anyref)\n");
    emit_indent(c, depth + 1); wat_append(c->w, "(call $tab_new)\n");
    int pos_idx = 1;
    for (int i = 0; i < n; i++) {
        TableEntry *ent = &e->as.table_ctor.entries[i];
        emit_indent(c, depth + 1); wat_append(c->w, "local.tee $tmp_tab\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(ref.as_non_null (local.get $tmp_tab))\n");
        if (ent->kind == TENT_POSITIONAL) {
            emit_indent(c, depth + 1);
            wat_appendf(c->w, "(ref.i31 (i32.const %d))\n", pos_idx++);
        } else {
            emit_expr(c, ent->key, depth + 1);
        }
        emit_expr(c, ent->value, depth + 1);
        emit_indent(c, depth + 1); wat_append(c->w, "call $tab_set\n");
    }
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* ----- main expression dispatch ----- */
static void emit_expr(CG *c, const Expr *e, int depth) {
    if (!c->ok) return;
    switch (e->kind) {
        case EXPR_NIL:
            emit_indent(c, depth); wat_append(c->w, "(ref.null any)\n"); break;
        case EXPR_TRUE:
            emit_indent(c, depth); wat_append(c->w, "(global.get $g_true)\n"); break;
        case EXPR_FALSE:
            emit_indent(c, depth); wat_append(c->w, "(global.get $g_false)\n"); break;
        case EXPR_INT:    emit_int_literal(c, e->as.i_val, depth); break;
        case EXPR_FLOAT:  emit_float_literal(c, e->as.f_val, depth); break;
        case EXPR_STRING: emit_string_literal(c, e->as.s.bytes, e->as.s.len, depth); break;
        case EXPR_VAR:    emit_var_read(c, e->as.var.kind, e->as.var.idx, depth); break;
        case EXPR_CALL:   emit_call(c, e, depth); break;
        case EXPR_BINOP:  emit_binop(c, e, depth); break;
        case EXPR_UNOP:   emit_unop(c, e, depth); break;
        case EXPR_FUNCTION: emit_function_expr(c, e->as.func_expr.func, depth); break;
        case EXPR_INDEX:  emit_index_expr(c, e, depth); break;
        case EXPR_TABLE:  emit_table_ctor(c, e, depth); break;
        case EXPR_METHOD_CALL: {
            /* Single-value context: wrap in $args_first. */
            emit_indent(c, depth); wat_append(c->w, "(call $args_first\n");
            emit_call_array(c, e, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            break;
        }
    }
}

/* Helper: emit code that pushes the i-th distributed value of a multi-value
 * binding/assignment.
 *
 *   n_values  = number of source expressions
 *   values    = those expressions
 *   last_call = nonzero iff values[n_values-1] is a CALL whose array result
 *               we want to splice in. The array is already in $tmp_args.
 *   i         = which target index we're filling (0-based)
 */
static void emit_distributed_value(CG *c, int i, int n_values, Expr **values,
                                   int last_call, int depth) {
    if (i < n_values - 1) {
        /* Plain expression at position i (single value). */
        emit_expr(c, values[i], depth);
        return;
    }
    if (i == n_values - 1) {
        if (last_call) {
            /* The trailing call. Take its first result. */
            emit_indent(c, depth);
            wat_append(c->w,
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0))\n");
        } else {
            emit_expr(c, values[i], depth);
        }
        return;
    }
    /* i > n_values - 1: only reachable if last_call (extra values from call) */
    if (last_call) {
        emit_indent(c, depth);
        wat_appendf(c->w,
            "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const %d))\n",
            i - (n_values - 1));
    } else {
        emit_indent(c, depth); wat_append(c->w, "(ref.null any)\n");
    }
}

/* ----- statements ----- */
static void emit_stmt(CG *c, const Stmt *s, int depth) {
    if (!c->ok) return;
    switch (s->kind) {
        case STMT_LOCAL: {
            int n_names = s->as.local.n_names;
            int n_values = s->as.local.n_values;
            int last_call = (n_values > 0 &&
                             (s->as.local.values[n_values - 1]->kind == EXPR_CALL ||
                              s->as.local.values[n_values - 1]->kind == EXPR_METHOD_CALL));
            if (last_call) {
                emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
                emit_call_array(c, s->as.local.values[n_values - 1], depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            for (int i = 0; i < n_names; i++) {
                emit_indent(c, depth);
                wat_appendf(c->w,
                    "(local.set $L%d (struct.new $Box\n",
                    s->as.local.local_idxs[i]);
                if (n_values == 0) {
                    emit_indent(c, depth + 1); wat_append(c->w, "(ref.null any)\n");
                } else {
                    emit_distributed_value(c, i, n_values, s->as.local.values,
                                           last_call, depth + 1);
                }
                emit_indent(c, depth); wat_append(c->w, "))\n");
            }
            break;
        }

        case STMT_ASSIGN: {
            int n_targets = s->as.assign.n_targets;
            int n_values = s->as.assign.n_values;
            int last_call = (n_values > 0 &&
                             (s->as.assign.values[n_values - 1]->kind == EXPR_CALL ||
                              s->as.assign.values[n_values - 1]->kind == EXPR_METHOD_CALL));
            if (n_targets == 1) {
                AssignTarget *t = &s->as.assign.targets[0];
                emit_target_open(c, t, depth);
                if (last_call) {
                    emit_indent(c, depth + 1); wat_append(c->w, "(call $args_first\n");
                    emit_call_array(c, s->as.assign.values[0], depth + 2);
                    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
                } else {
                    emit_expr(c, s->as.assign.values[0], depth + 1);
                }
                emit_target_close(c, t, depth);
                break;
            }
            /* Multi-target: must evaluate ALL RHS before assigning (Lua spec).
             * Build $tmp_args from singles (and merge with trailing call's
             * results if applicable). */
            int singles_count = n_values - (last_call ? 1 : 0);
            emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
            if (last_call) {
                emit_indent(c, depth + 1); wat_append(c->w, "(call $merge_args\n");
                emit_indent(c, depth + 2);
                wat_appendf(c->w, "(array.new_fixed $ArgArr %d\n", singles_count);
                for (int i = 0; i < singles_count; i++) {
                    emit_expr(c, s->as.assign.values[i], depth + 3);
                }
                if (singles_count == 0) {
                    /* Avoid empty array.new_fixed inside the helper call. */
                    emit_indent(c, depth + 2); wat_append(c->w, ")\n");
                    /* Replace with empty global to be safe. */
                } else {
                    emit_indent(c, depth + 2); wat_append(c->w, ")\n");
                }
                emit_call_array(c, s->as.assign.values[n_values - 1], depth + 2);
                emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            } else {
                emit_indent(c, depth + 1);
                wat_appendf(c->w, "(array.new_fixed $ArgArr %d\n", n_values);
                for (int i = 0; i < n_values; i++) {
                    emit_expr(c, s->as.assign.values[i], depth + 2);
                }
                emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            }
            emit_indent(c, depth); wat_append(c->w, ")\n");
            for (int i = 0; i < n_targets; i++) {
                AssignTarget *t = &s->as.assign.targets[i];
                emit_target_open(c, t, depth);
                emit_indent(c, depth + 1);
                wat_appendf(c->w,
                    "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                    "(i32.const %d))\n", i);
                emit_target_close(c, t, depth);
            }
            break;
        }

        case STMT_EXPR:
            /* Call as statement: get array, drop it. */
            emit_call_array(c, s->as.expr_stmt.expr, depth);
            emit_indent(c, depth); wat_append(c->w, "drop\n");
            break;

        case STMT_DO:
            emit_block(c, &s->as.do_stmt.body, depth);
            break;

        case STMT_RETURN: {
            int n_values = s->as.return_stmt.n_values;
            if (c->in_main) {
                /* main: chunk-return value ignored, no return type. */
                emit_indent(c, depth); wat_append(c->w, "return\n");
                break;
            }
            /* Tail-call optimization: exactly `return <call_expr>` (regular
             * or method form — method calls just need their args array set up
             * via emit_call_array equivalent; here we only TCO the regular form). */
            if (n_values == 1 && s->as.return_stmt.values[0]->kind == EXPR_CALL) {
                emit_tail_call(c, s->as.return_stmt.values[0], depth);
                break;
            }
            /* Otherwise build the result array and return it. */
            if (n_values == 0) {
                emit_indent(c, depth); wat_append(c->w, "(global.get $g_empty_args)\n");
            } else {
                emit_indent(c, depth);
                wat_appendf(c->w, "(array.new_fixed $ArgArr %d\n", n_values);
                for (int i = 0; i < n_values; i++) {
                    emit_expr(c, s->as.return_stmt.values[i], depth + 1);
                }
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            emit_indent(c, depth); wat_append(c->w, "return\n");
            break;
        }

        case STMT_WHILE: {
            int label = c->next_label++;
            c->break_labels[c->break_depth++] = label;
            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            emit_expr(c, s->as.while_stmt.cond, depth + 2);
            emit_indent(c, depth + 2); wat_append(c->w, "(call $lua_truthy)\n");
            emit_indent(c, depth + 2); wat_append(c->w, "i32.eqz\n");
            emit_indent(c, depth + 2); wat_appendf(c->w, "br_if $brk_%d\n", label);
            emit_block(c, &s->as.while_stmt.body, depth + 2);
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            c->break_depth--;
            break;
        }

        case STMT_REPEAT: {
            int label = c->next_label++;
            c->break_labels[c->break_depth++] = label;
            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            emit_block(c, &s->as.repeat.body, depth + 2);
            emit_expr(c, s->as.repeat.cond, depth + 2);
            emit_indent(c, depth + 2); wat_append(c->w, "(call $lua_truthy)\n");
            emit_indent(c, depth + 2); wat_append(c->w, "i32.eqz\n");
            emit_indent(c, depth + 2); wat_appendf(c->w, "br_if $cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            c->break_depth--;
            break;
        }

        case STMT_BREAK: {
            if (c->break_depth == 0) {
                cg_error(c, "break outside loop"); break;
            }
            int label = c->break_labels[c->break_depth - 1];
            emit_indent(c, depth);
            wat_appendf(c->w, "br $brk_%d\n", label);
            break;
        }

        case STMT_FOR_NUM: {
            int label = c->next_label++;
            c->break_labels[c->break_depth++] = label;
            int slot = s->as.for_num.local_idx;
            /* Initialize control variable's box with `start`, and stash
             * stop/step in scratch locals. */
            emit_indent(c, depth);
            wat_appendf(c->w, "(local.set $L%d (struct.new $Box\n", slot);
            emit_expr(c, s->as.for_num.start, depth + 1);
            emit_indent(c, depth); wat_append(c->w, "))\n");
            emit_indent(c, depth); wat_append(c->w, "(local.set $for_stop\n");
            emit_expr(c, s->as.for_num.stop, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            emit_indent(c, depth); wat_append(c->w, "(local.set $for_step\n");
            if (s->as.for_num.step) {
                emit_expr(c, s->as.for_num.step, depth + 1);
            } else {
                emit_indent(c, depth + 1); wat_append(c->w, "(ref.i31 (i32.const 1))\n");
            }
            emit_indent(c, depth); wat_append(c->w, ")\n");

            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            /* terminate? */
            emit_indent(c, depth + 2);
            wat_append(c->w,
                "(if (call $for_step_positive (local.get $for_step))\n");
            emit_indent(c, depth + 2); wat_append(c->w, "  (then\n");
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "    (br_if $brk_%d (i32.eqz (call $num_le\n"
                "      (struct.get $Box $v (local.get $L%d))\n"
                "      (local.get $for_stop)))))\n", label, slot);
            emit_indent(c, depth + 2); wat_append(c->w, "  (else\n");
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "    (br_if $brk_%d (i32.eqz (call $num_le\n"
                "      (local.get $for_stop)\n"
                "      (struct.get $Box $v (local.get $L%d)))))))\n", label, slot);
            /* body */
            emit_block(c, &s->as.for_num.body, depth + 2);
            /* i = i + step */
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "(struct.set $Box $v (local.get $L%d) "
                "(call $lua_add (struct.get $Box $v (local.get $L%d)) "
                "(local.get $for_step)))\n", slot, slot);
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            c->break_depth--;
            break;
        }

        case STMT_FOR_GEN: {
            /* Generic for: `for v1[, v2, ...] in iter [, state [, init]] do body end`.
             * Evaluate the expr_list into ($for_iter_any, $for_state, $for_k),
             * then loop: call iter(state, k); if first result is nil, break;
             * otherwise bind v1..vN to results, set k = result[0]. */
            int label = c->next_label++;
            c->break_labels[c->break_depth++] = label;
            int n_exprs = s->as.for_gen.n_exprs;
            int last_call = (n_exprs > 0 &&
                             (s->as.for_gen.exprs[n_exprs - 1]->kind == EXPR_CALL ||
                              s->as.for_gen.exprs[n_exprs - 1]->kind == EXPR_METHOD_CALL));
            /* Compute the full args array via the same singles+merge pattern. */
            int singles = n_exprs - (last_call ? 1 : 0);
            emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
            if (last_call) {
                emit_indent(c, depth + 1); wat_append(c->w, "(call $merge_args\n");
                emit_indent(c, depth + 2);
                wat_appendf(c->w, "(array.new_fixed $ArgArr %d\n", singles);
                for (int i = 0; i < singles; i++) emit_expr(c, s->as.for_gen.exprs[i], depth + 3);
                emit_indent(c, depth + 2); wat_append(c->w, ")\n");
                emit_call_array(c, s->as.for_gen.exprs[n_exprs - 1], depth + 2);
                emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            } else {
                emit_indent(c, depth + 1);
                wat_appendf(c->w, "(array.new_fixed $ArgArr %d\n", n_exprs);
                for (int i = 0; i < n_exprs; i++) emit_expr(c, s->as.for_gen.exprs[i], depth + 2);
                emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            }
            emit_indent(c, depth); wat_append(c->w, ")\n");
            /* iter = args[0]; state = args[1]; k = args[2]. */
            emit_indent(c, depth); wat_append(c->w,
                "(local.set $for_iter_any "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0)))\n");
            emit_indent(c, depth); wat_append(c->w,
                "(local.set $for_state "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 1)))\n");
            emit_indent(c, depth); wat_append(c->w,
                "(local.set $for_k "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 2)))\n");

            /* Pre-allocate boxes for the loop variables. */
            for (int i = 0; i < s->as.for_gen.n_names; i++) {
                emit_indent(c, depth);
                wat_appendf(c->w,
                    "(local.set $L%d (struct.new $Box (ref.null any)))\n",
                    s->as.for_gen.local_idxs[i]);
            }

            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            /* Call iter(state, k). */
            emit_indent(c, depth + 2); wat_append(c->w, "(local.set $tmp_args\n");
            emit_indent(c, depth + 3); wat_append(c->w, "(call $lua_call\n");
            emit_indent(c, depth + 4);
            wat_append(c->w,
                "(ref.cast (ref $LuaClosure) (local.get $for_iter_any))\n");
            emit_indent(c, depth + 4);
            wat_append(c->w,
                "(array.new_fixed $ArgArr 2 (local.get $for_state) (local.get $for_k))\n");
            emit_indent(c, depth + 3); wat_append(c->w, ")\n");
            emit_indent(c, depth + 2); wat_append(c->w, ")\n");
            /* terminate if results[0] is nil */
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "(br_if $brk_%d (ref.is_null "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0))))\n",
                label);
            /* update k to results[0] */
            emit_indent(c, depth + 2);
            wat_append(c->w,
                "(local.set $for_k "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0)))\n");
            /* bind loop vars from results */
            for (int i = 0; i < s->as.for_gen.n_names; i++) {
                emit_indent(c, depth + 2);
                wat_appendf(c->w,
                    "(struct.set $Box $v (local.get $L%d) "
                    "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                    "(i32.const %d)))\n",
                    s->as.for_gen.local_idxs[i], i);
            }
            /* body */
            emit_block(c, &s->as.for_gen.body, depth + 2);
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            c->break_depth--;
            break;
        }

        case STMT_GLOBAL: {
            int n_names = s->as.global_decl.n_names;
            int n_values = s->as.global_decl.n_values;
            if (n_values == 0) break;
            int last_call = (n_values > 0 &&
                             (s->as.global_decl.values[n_values - 1]->kind == EXPR_CALL ||
                              s->as.global_decl.values[n_values - 1]->kind == EXPR_METHOD_CALL));
            if (last_call) {
                emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
                emit_call_array(c, s->as.global_decl.values[n_values - 1], depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            for (int i = 0; i < n_names; i++) {
                emit_indent(c, depth);
                wat_appendf(c->w, "(global.set $g_user_%d\n", s->as.global_decl.global_idxs[i]);
                if (n_values == 0) {
                    emit_indent(c, depth + 1); wat_append(c->w, "(ref.null any)\n");
                } else {
                    emit_distributed_value(c, i, n_values, s->as.global_decl.values,
                                           last_call, depth + 1);
                }
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            break;
        }

        case STMT_IF: {
            int label = c->next_label++;
            emit_indent(c, depth);
            wat_appendf(c->w, "(block $if_end_%d\n", label);
            for (size_t i = 0; i < s->as.if_stmt.narms; i++) {
                IfArm *a = &s->as.if_stmt.arms[i];
                emit_expr(c, a->cond, depth + 1);
                emit_indent(c, depth + 1); wat_append(c->w, "(call $lua_truthy)\n");
                emit_indent(c, depth + 1); wat_append(c->w, "(if (then\n");
                emit_block(c, &a->body, depth + 2);
                emit_indent(c, depth + 2); wat_appendf(c->w, "br $if_end_%d\n", label);
                emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            }
            if (s->as.if_stmt.has_else) {
                emit_block(c, &s->as.if_stmt.else_body, depth + 1);
            }
            emit_indent(c, depth); wat_append(c->w, ")\n");
            break;
        }

        case STMT_LOCAL_FUNC: {
            /* Pre-allocate the box with nil so the function body can capture
             * its own slot (recursion). Then build the closure (which may
             * capture this very slot via UPVAL_FROM_LOCAL). Finally store
             * the closure into the box. */
            emit_indent(c, depth);
            wat_appendf(c->w,
                "(local.set $L%d (struct.new $Box (ref.null any)))\n",
                s->as.local_func.local_idx);
            emit_indent(c, depth); wat_append(c->w, "(struct.set $Box $v\n");
            emit_indent(c, depth + 1);
            wat_appendf(c->w, "(local.get $L%d)\n", s->as.local_func.local_idx);
            emit_function_expr(c, s->as.local_func.func, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            break;
        }
    }
}

static void emit_block(CG *c, const Block *b, int depth) {
    for (size_t i = 0; i < b->count; i++) emit_stmt(c, b->items[i], depth);
}

/* ============================================================
 * Static prelude
 * ============================================================ */

static const char *PRELUDE_TYPES =
"  ;; --- value-rep types ---\n"
"  (type $LuaArr    (array (mut i8)))\n"
"  (type $LuaString (sub (struct (field $bytes (ref $LuaArr)))))\n"
"  (type $LuaFloat  (sub (struct (field $v f64))))\n"
"  (type $LuaInt    (sub (struct (field $v i64))))\n"
"  (type $LuaBool   (sub (struct (field $b i32))))\n"
"  ;; --- closure / function types (mutually recursive) ---\n"
"  (type $Box       (sub (struct (field $v (mut anyref)))))\n"
"  (type $ArgArr    (array (mut anyref)))\n"
"  (type $UpvalArr  (array (mut (ref $Box))))\n"
"  (rec\n"
"    (type $LuaClosure (sub (struct (field $code (ref $LuaFn))\n"
"                                   (field $upvals (ref $UpvalArr)))))\n"
"    (type $LuaFn (func (param (ref $LuaClosure))\n"
"                       (param (ref $ArgArr))\n"
"                       (result (ref $ArgArr)))))\n"
"  ;; --- table type ---\n"
"  (type $TArr (array (mut anyref)))\n"
"  (rec\n"
"    (type $LuaTable (sub (struct\n"
"      (field $keys (mut (ref null $TArr)))\n"
"      (field $vals (mut (ref null $TArr)))\n"
"      (field $n    (mut i32))\n"
"      (field $cap  (mut i32))\n"
"      (field $meta (mut (ref null $LuaTable)))))))\n"
"\n"
"  (import \"host\" \"print\" (func $host_print (param anyref)))\n"
"  (import \"host\" \"write_raw\" (func $host_write_raw (param anyref)))\n"
"  ;; host_fmt: format one value into the shared $fmt_buf scratch array.\n"
"  ;;   kind: 0 = %d (i_val)   1 = unused (s handled wasm-side)\n"
"  ;;         2 = %g (f_val + prec)   3 = %f   4 = %e   5 = %x (i_val)\n"
"  ;; Returns the number of bytes written.\n"
"  (import \"host\" \"fmt\" (func $host_fmt (param i32) (param i64) (param f64) (param i32) (result i32)))\n"
"  ;; host_math: dispatch transcendental functions to the JS Math API.\n"
"  ;;   0 sin  1 cos  2 tan  3 asin  4 acos  5 atan  6 exp  7 log\n"
"  (import \"host\" \"math\" (func $host_math (param i32) (param f64) (result f64)))\n"
"  ;; host_read: read next line from stdin into $fmt_buf and return the\n"
"  ;; length; returns -1 on EOF.\n"
"  (import \"host\" \"read\" (func $host_read (result i32)))\n"
"\n"
"  ;; --- singletons ---\n"
"  (global $g_true  (ref $LuaBool) (struct.new $LuaBool (i32.const 1)))\n"
"  (global $g_false (ref $LuaBool) (struct.new $LuaBool (i32.const 0)))\n"
"  (global $g_empty_upvals (ref $UpvalArr) (array.new_fixed $UpvalArr 0))\n"
"  (global $g_empty_args   (ref $ArgArr)   (array.new_fixed $ArgArr 0))\n"
"  ;; Scratch byte buffer that host_fmt writes into (set up by stdlib_init).\n"
"  (global $fmt_buf (mut (ref null $LuaArr)) (ref.null $LuaArr))\n";

static const char *PRELUDE_HELPERS =
"  ;; --- truthiness: only nil and false are falsy ---\n"
"  (func $lua_truthy (param $v anyref) (result i32)\n"
"    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))\n"
"    (if (ref.test (ref $LuaBool) (local.get $v))\n"
"      (then (return (struct.get $LuaBool $b\n"
"               (ref.cast (ref $LuaBool) (local.get $v))))))\n"
"    (i32.const 1))\n"
"\n"
"  (func $lua_bool_to_ref (param $b i32) (result anyref)\n"
"    (if (result anyref) (local.get $b)\n"
"      (then (global.get $g_true))\n"
"      (else (global.get $g_false))))\n"
"\n"
"  ;; --- numeric type predicates and accessors ---\n"
"  (func $is_int (param $v anyref) (result i32)\n"
"    (if (result i32) (ref.test (ref i31) (local.get $v))\n"
"      (then (i32.const 1))\n"
"      (else (ref.test (ref $LuaInt) (local.get $v)))))\n"
"\n"
"  (func $is_float (param $v anyref) (result i32)\n"
"    (ref.test (ref $LuaFloat) (local.get $v)))\n"
"\n"
"  (func $as_int (param $v anyref) (result i64)\n"
"    (if (result i64) (ref.test (ref i31) (local.get $v))\n"
"      (then (i64.extend_i32_s\n"
"              (i31.get_s (ref.cast (ref i31) (local.get $v)))))\n"
"      (else (struct.get $LuaInt $v\n"
"              (ref.cast (ref $LuaInt) (local.get $v))))))\n"
"\n"
"  (func $as_float (param $v anyref) (result f64)\n"
"    (if (result f64) (call $is_float (local.get $v))\n"
"      (then (struct.get $LuaFloat $v\n"
"              (ref.cast (ref $LuaFloat) (local.get $v))))\n"
"      (else (f64.convert_i64_s (call $as_int (local.get $v))))))\n"
"\n"
"  (func $make_int (param $v i64) (result anyref)\n"
"    (if (result anyref)\n"
"      (i32.and\n"
"        (i64.ge_s (local.get $v) (i64.const -1073741824))\n"
"        (i64.lt_s (local.get $v) (i64.const  1073741824)))\n"
"      (then (ref.i31 (i32.wrap_i64 (local.get $v))))\n"
"      (else (struct.new $LuaInt (local.get $v)))))\n"
"\n"
"  (func $make_float (param $v f64) (result anyref)\n"
"    (struct.new $LuaFloat (local.get $v)))\n"
"\n"
"  ;; --- arithmetic: int+int -> int; else promote to float ---\n"
"  (func $is_numlike (param $v anyref) (result i32)\n"
"    (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v))))\n"
"\n"
"  (func $lua_add (param $a anyref) (param $b anyref) (result anyref)\n"
"    (local $mm anyref)\n"
"    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))\n"
"      (then\n"
"        (if (result anyref)\n"
"          (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"          (then (return (call $make_int (i64.add (call $as_int (local.get $a))\n"
"                                                  (call $as_int (local.get $b))))))\n"
"          (else (return (call $make_float (f64.add (call $as_float (local.get $a))\n"
"                                                    (call $as_float (local.get $b)))))))))\n"
"    ;; metamethod path\n"
"    (local.set $mm (call $get_metamethod (local.get $a) (ref.as_non_null (global.get $g_mkey_add))))\n"
"    (if (ref.is_null (local.get $mm))\n"
"      (then (local.set $mm (call $get_metamethod (local.get $b) (ref.as_non_null (global.get $g_mkey_add))))))\n"
"    (if (ref.is_null (local.get $mm))\n"
"      (then (throw $LuaError (ref.null any))))\n"
"    (call $args_first (call $lua_call\n"
"      (ref.cast (ref $LuaClosure) (local.get $mm))\n"
"      (array.new_fixed $ArgArr 2 (local.get $a) (local.get $b)))))\n"
"\n"
"  (func $lua_sub (param $a anyref) (param $b anyref) (result anyref)\n"
"    (if (result anyref)\n"
"      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"      (then (call $make_int (i64.sub (call $as_int (local.get $a))\n"
"                                     (call $as_int (local.get $b)))))\n"
"      (else (call $make_float (f64.sub (call $as_float (local.get $a))\n"
"                                       (call $as_float (local.get $b)))))))\n"
"\n"
"  (func $lua_mul (param $a anyref) (param $b anyref) (result anyref)\n"
"    (if (result anyref)\n"
"      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"      (then (call $make_int (i64.mul (call $as_int (local.get $a))\n"
"                                     (call $as_int (local.get $b)))))\n"
"      (else (call $make_float (f64.mul (call $as_float (local.get $a))\n"
"                                       (call $as_float (local.get $b)))))))\n"
"\n"
"  ;; / always yields float (Lua 5.4/5.5)\n"
"  (func $lua_div (param $a anyref) (param $b anyref) (result anyref)\n"
"    (call $make_float (f64.div (call $as_float (local.get $a))\n"
"                               (call $as_float (local.get $b)))))\n"
"\n"
"  (func $lua_fdiv (param $a anyref) (param $b anyref) (result anyref)\n"
"    (if (result anyref)\n"
"      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"      (then (call $make_int (i64.div_s (call $as_int (local.get $a))\n"
"                                       (call $as_int (local.get $b)))))\n"
"      (else (call $make_float (f64.floor\n"
"              (f64.div (call $as_float (local.get $a))\n"
"                       (call $as_float (local.get $b))))))))\n"
"\n"
"  (func $lua_mod (param $a anyref) (param $b anyref) (result anyref)\n"
"    (if (result anyref)\n"
"      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"      (then (call $make_int (i64.rem_s (call $as_int (local.get $a))\n"
"                                       (call $as_int (local.get $b)))))\n"
"      (else (call $make_float (f64.const 0)))))   ;; v2 stub: float % returns 0\n"
"\n"
"  (func $lua_pow (param $a anyref) (param $b anyref) (result anyref)\n"
"    (local $base f64) (local $exp f64) (local $r f64) (local $i i32)\n"
"    (local.set $base (call $as_float (local.get $a)))\n"
"    (local.set $exp  (call $as_float (local.get $b)))\n"
"    (local.set $r (f64.const 1))\n"
"    (local.set $i (i32.trunc_f64_s (local.get $exp)))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.le_s (local.get $i) (i32.const 0)))\n"
"      (local.set $r (f64.mul (local.get $r) (local.get $base)))\n"
"      (local.set $i (i32.sub (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (call $make_float (local.get $r)))\n"
"\n"
"  (func $lua_neg (param $a anyref) (result anyref)\n"
"    (if (result anyref) (call $is_int (local.get $a))\n"
"      (then (call $make_int (i64.sub (i64.const 0) (call $as_int (local.get $a)))))\n"
"      (else (call $make_float (f64.neg (call $as_float (local.get $a)))))))\n"
"\n"
"  (func $lua_not (param $a anyref) (result anyref)\n"
"    (call $lua_bool_to_ref (i32.eqz (call $lua_truthy (local.get $a)))))\n"
"\n"
"  (func $lua_len (param $a anyref) (result anyref)\n"
"    (if (result anyref) (ref.test (ref $LuaTable) (local.get $a))\n"
"      (then (call $make_int (i64.extend_i32_s\n"
"              (call $tab_len (ref.cast (ref $LuaTable) (local.get $a))))))\n"
"      (else (call $make_int (i64.extend_i32_u\n"
"        (array.len (struct.get $LuaString $bytes\n"
"          (ref.cast (ref $LuaString) (local.get $a)))))))))\n"
"\n"
"  ;; --- comparison ---\n"
"  (func $num_eq (param $a anyref) (param $b anyref) (result i32)\n"
"    (if (result i32)\n"
"      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"      (then (i64.eq (call $as_int (local.get $a)) (call $as_int (local.get $b))))\n"
"      (else (f64.eq (call $as_float (local.get $a)) (call $as_float (local.get $b))))))\n"
"\n"
"  (func $str_eq (param $a anyref) (param $b anyref) (result i32)\n"
"    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr))\n"
"    (local $i i32) (local $n i32)\n"
"    (local.set $sa (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $a))))\n"
"    (local.set $sb (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $b))))\n"
"    (local.set $n (array.len (local.get $sa)))\n"
"    (if (i32.ne (local.get $n) (array.len (local.get $sb)))\n"
"      (then (return (i32.const 0))))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (if (i32.ne (array.get_u $LuaArr (local.get $sa) (local.get $i))\n"
"                  (array.get_u $LuaArr (local.get $sb) (local.get $i)))\n"
"        (then (return (i32.const 0))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (i32.const 1))\n"
"\n"
"  (func $lua_eq_raw (param $a anyref) (param $b anyref) (result i32)\n"
"    (local $mm anyref)\n"
"    (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))\n"
"      (then (return (i32.const 1))))\n"
"    (if (i32.or  (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))\n"
"      (then (return (i32.const 0))))\n"
"    (if (i32.and (ref.test (ref $LuaBool) (local.get $a))\n"
"                 (ref.test (ref $LuaBool) (local.get $b)))\n"
"      (then (return (i32.eq\n"
"        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $a)))\n"
"        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $b)))))))\n"
"    (if (i32.and\n"
"          (i32.or (call $is_int (local.get $a)) (call $is_float (local.get $a)))\n"
"          (i32.or (call $is_int (local.get $b)) (call $is_float (local.get $b))))\n"
"      (then (return (call $num_eq (local.get $a) (local.get $b)))))\n"
"    (if (i32.and (ref.test (ref $LuaString) (local.get $a))\n"
"                 (ref.test (ref $LuaString) (local.get $b)))\n"
"      (then (return (call $str_eq (local.get $a) (local.get $b)))))\n"
"    ;; Two tables: consult __eq if present, otherwise compare by identity.\n"
"    (if (i32.and (ref.test (ref $LuaTable) (local.get $a))\n"
"                 (ref.test (ref $LuaTable) (local.get $b)))\n"
"      (then\n"
"        (local.set $mm (call $get_metamethod (local.get $a) (ref.as_non_null (global.get $g_mkey_eq))))\n"
"        (if (ref.is_null (local.get $mm))\n"
"          (then (return (ref.eq (ref.cast (ref null eq) (local.get $a))\n"
"                                 (ref.cast (ref null eq) (local.get $b))))))\n"
"        (return (call $lua_truthy (call $args_first (call $lua_call\n"
"          (ref.cast (ref $LuaClosure) (local.get $mm))\n"
"          (array.new_fixed $ArgArr 2 (local.get $a) (local.get $b))))))))\n"
"    ;; Any other matched ref types (closures, etc.): identity via ref.eq.\n"
"    (if (i32.and (ref.test (ref eq) (local.get $a))\n"
"                 (ref.test (ref eq) (local.get $b)))\n"
"      (then (return (ref.eq (ref.cast (ref null eq) (local.get $a))\n"
"                             (ref.cast (ref null eq) (local.get $b))))))\n"
"    (i32.const 0))\n"
"\n"
"  (func $lua_eq  (param $a anyref) (param $b anyref) (result anyref)\n"
"    (call $lua_bool_to_ref (call $lua_eq_raw (local.get $a) (local.get $b))))\n"
"  (func $lua_neq (param $a anyref) (param $b anyref) (result anyref)\n"
"    (call $lua_bool_to_ref (i32.eqz (call $lua_eq_raw (local.get $a) (local.get $b)))))\n"
"\n"
"  (func $num_lt (param $a anyref) (param $b anyref) (result i32)\n"
"    (if (result i32)\n"
"      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"      (then (i64.lt_s (call $as_int (local.get $a)) (call $as_int (local.get $b))))\n"
"      (else (f64.lt (call $as_float (local.get $a)) (call $as_float (local.get $b))))))\n"
"\n"
"  (func $num_le (param $a anyref) (param $b anyref) (result i32)\n"
"    (if (result i32)\n"
"      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"      (then (i64.le_s (call $as_int (local.get $a)) (call $as_int (local.get $b))))\n"
"      (else (f64.le (call $as_float (local.get $a)) (call $as_float (local.get $b))))))\n"
"\n"
"  (func $lua_lt (param $a anyref) (param $b anyref) (result anyref)\n"
"    (call $lua_bool_to_ref (call $num_lt (local.get $a) (local.get $b))))\n"
"  (func $lua_le (param $a anyref) (param $b anyref) (result anyref)\n"
"    (call $lua_bool_to_ref (call $num_le (local.get $a) (local.get $b))))\n"
"  (func $lua_gt (param $a anyref) (param $b anyref) (result anyref)\n"
"    (call $lua_bool_to_ref (call $num_lt (local.get $b) (local.get $a))))\n"
"  (func $lua_ge (param $a anyref) (param $b anyref) (result anyref)\n"
"    (call $lua_bool_to_ref (call $num_le (local.get $b) (local.get $a))))\n"
"\n"
"  ;; --- string conversion + concat ---\n"
"  (func $int_to_bytes (param $v i64) (result (ref $LuaArr))\n"
"    (local $neg i32)\n"
"    (local $tmp (ref $LuaArr)) (local $n i32)\n"
"    (local $out (ref $LuaArr))\n"
"    (local $i i32) (local $j i32) (local $d i32) (local $total i32)\n"
"    (if (i64.lt_s (local.get $v) (i64.const 0))\n"
"      (then\n"
"        (local.set $neg (i32.const 1))\n"
"        (local.set $v (i64.sub (i64.const 0) (local.get $v)))))\n"
"    (local.set $tmp (array.new $LuaArr (i32.const 0) (i32.const 21)))\n"
"    (loop $lp\n"
"      (local.set $d (i32.wrap_i64 (i64.rem_u (local.get $v) (i64.const 10))))\n"
"      (local.set $v (i64.div_u (local.get $v) (i64.const 10)))\n"
"      (array.set $LuaArr (local.get $tmp) (local.get $n)\n"
"        (i32.add (local.get $d) (i32.const 48)))\n"
"      (local.set $n (i32.add (local.get $n) (i32.const 1)))\n"
"      (br_if $lp (i64.ne (local.get $v) (i64.const 0))))\n"
"    (local.set $total (local.get $n))\n"
"    (if (local.get $neg)\n"
"      (then (local.set $total (i32.add (local.get $total) (i32.const 1)))))\n"
"    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $total)))\n"
"    (if (local.get $neg)\n"
"      (then\n"
"        (array.set $LuaArr (local.get $out) (i32.const 0) (i32.const 45))\n"
"        (local.set $j (i32.const 1))))\n"
"    (local.set $i (i32.sub (local.get $n) (i32.const 1)))\n"
"    (block $done (loop $cp\n"
"      (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))\n"
"      (array.set $LuaArr (local.get $out) (local.get $j)\n"
"        (array.get_u $LuaArr (local.get $tmp) (local.get $i)))\n"
"      (local.set $j (i32.add (local.get $j) (i32.const 1)))\n"
"      (local.set $i (i32.sub (local.get $i) (i32.const 1)))\n"
"      (br $cp)))\n"
"    (local.get $out))\n"
"\n"
"  ;; Float-to-bytes via host_fmt kind=6 (Lua tostring style: \"1.0\" for\n"
"  ;; integer-valued floats, %.14g w/ trailing-zero trim otherwise).\n"
"  (func $float_to_bytes (param $v f64) (result (ref $LuaArr))\n"
"    (local $n i32) (local $out (ref $LuaArr))\n"
"    (local.set $n (call $host_fmt (i32.const 6) (i64.const 0)\n"
"                       (local.get $v) (i32.const -1)))\n"
"    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))\n"
"    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)\n"
"      (ref.as_non_null (global.get $fmt_buf)) (i32.const 0) (local.get $n))\n"
"    (local.get $out))\n"
"\n"
"  (func $lua_tostring (param $v anyref) (result (ref $LuaString))\n"
"    (if (result (ref $LuaString)) (ref.is_null (local.get $v))\n"
"      (then (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
"               (i32.const 0) (i32.const 3))))\n"
"      (else (if (result (ref $LuaString)) (ref.test (ref $LuaBool) (local.get $v))\n"
"        (then (if (result (ref $LuaString))\n"
"                  (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v)))\n"
"          (then (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
"                  (i32.const 3) (i32.const 4))))\n"
"          (else (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
"                  (i32.const 7) (i32.const 5))))))\n"
"        (else (if (result (ref $LuaString)) (ref.test (ref $LuaString) (local.get $v))\n"
"          (then (ref.cast (ref $LuaString) (local.get $v)))\n"
"          (else (if (result (ref $LuaString)) (call $is_int (local.get $v))\n"
"            (then (struct.new $LuaString (call $int_to_bytes (call $as_int (local.get $v)))))\n"
"            (else (struct.new $LuaString (call $float_to_bytes (call $as_float (local.get $v)))))))))))))\n"
"\n"
"  (func $lua_concat (param $a anyref) (param $b anyref) (result anyref)\n"
"    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr)) (local $out (ref $LuaArr))\n"
"    (local $na i32) (local $nb i32)\n"
"    (local.set $sa (struct.get $LuaString $bytes (call $lua_tostring (local.get $a))))\n"
"    (local.set $sb (struct.get $LuaString $bytes (call $lua_tostring (local.get $b))))\n"
"    (local.set $na (array.len (local.get $sa)))\n"
"    (local.set $nb (array.len (local.get $sb)))\n"
"    (local.set $out (array.new $LuaArr (i32.const 0)\n"
"                       (i32.add (local.get $na) (local.get $nb))))\n"
"    (array.copy $LuaArr $LuaArr\n"
"      (local.get $out) (i32.const 0)\n"
"      (local.get $sa)  (i32.const 0) (local.get $na))\n"
"    (array.copy $LuaArr $LuaArr\n"
"      (local.get $out) (local.get $na)\n"
"      (local.get $sb)  (i32.const 0) (local.get $nb))\n"
"    (struct.new $LuaString (local.get $out)))\n"
"\n"
"  ;; --- tables (linear-search hash; perf is a phase-7 concern) ---\n"
"  (func $tab_new (result (ref $LuaTable))\n"
"    (struct.new $LuaTable (ref.null $TArr) (ref.null $TArr) (i32.const 0) (i32.const 0) (ref.null $LuaTable)))\n"
"\n"
"  ;; Grow keys/vals arrays to at least new_cap; copies old contents.\n"
"  (func $tab_grow (param $t (ref $LuaTable)) (param $new_cap i32)\n"
"    (local $nk (ref $TArr)) (local $nv (ref $TArr))\n"
"    (local $oldk (ref null $TArr)) (local $oldv (ref null $TArr))\n"
"    (local $n i32)\n"
"    (local.set $nk (array.new $TArr (ref.null any) (local.get $new_cap)))\n"
"    (local.set $nv (array.new $TArr (ref.null any) (local.get $new_cap)))\n"
"    (local.set $oldk (struct.get $LuaTable $keys (local.get $t)))\n"
"    (local.set $oldv (struct.get $LuaTable $vals (local.get $t)))\n"
"    (local.set $n    (struct.get $LuaTable $n    (local.get $t)))\n"
"    (if (ref.is_null (local.get $oldk))\n"
"      (then)\n"
"      (else\n"
"        (array.copy $TArr $TArr (local.get $nk) (i32.const 0)\n"
"          (ref.as_non_null (local.get $oldk)) (i32.const 0) (local.get $n))\n"
"        (array.copy $TArr $TArr (local.get $nv) (i32.const 0)\n"
"          (ref.as_non_null (local.get $oldv)) (i32.const 0) (local.get $n))))\n"
"    (struct.set $LuaTable $keys (local.get $t) (local.get $nk))\n"
"    (struct.set $LuaTable $vals (local.get $t) (local.get $nv))\n"
"    (struct.set $LuaTable $cap  (local.get $t) (local.get $new_cap)))\n"
"\n"
"  ;; Linear scan; returns index in 0..n-1 or -1 if not present.\n"
"  (func $tab_find (param $t (ref $LuaTable)) (param $k anyref) (result i32)\n"
"    (local $keys (ref null $TArr)) (local $n i32) (local $i i32)\n"
"    (local.set $keys (struct.get $LuaTable $keys (local.get $t)))\n"
"    (local.set $n (struct.get $LuaTable $n (local.get $t)))\n"
"    (if (ref.is_null (local.get $keys)) (then (return (i32.const -1))))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (if (call $lua_eq_raw\n"
"            (array.get $TArr (ref.as_non_null (local.get $keys)) (local.get $i))\n"
"            (local.get $k))\n"
"        (then (return (local.get $i))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (i32.const -1))\n"
"\n"
"  (func $tab_get_raw (param $t (ref $LuaTable)) (param $k anyref) (result anyref)\n"
"    (local $i i32) (local $vals (ref null $TArr))\n"
"    (local.set $i (call $tab_find (local.get $t) (local.get $k)))\n"
"    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return (ref.null any))))\n"
"    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))\n"
"    (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $i)))\n"
"\n"
"  ;; Lookup that walks the __index metamethod chain (with cycle limit).\n"
"  (func $tab_get (param $t (ref $LuaTable)) (param $k anyref) (result anyref)\n"
"    (local $v anyref) (local $mt (ref null $LuaTable)) (local $idx anyref)\n"
"    (local $cur (ref $LuaTable)) (local $depth i32)\n"
"    (local.set $cur (local.get $t))\n"
"    (local.set $depth (i32.const 64))\n"
"    (block $done (result anyref) (loop $lp\n"
"      (local.set $v (call $tab_get_raw (local.get $cur) (local.get $k)))\n"
"      (if (i32.eqz (ref.is_null (local.get $v))) (then (br $done (local.get $v))))\n"
"      (local.set $mt (struct.get $LuaTable $meta (local.get $cur)))\n"
"      (if (ref.is_null (local.get $mt)) (then (br $done (ref.null any))))\n"
"      (local.set $idx (call $tab_get_raw (ref.as_non_null (local.get $mt))\n"
"                                          (ref.as_non_null (global.get $g_mkey_index))))\n"
"      (if (ref.is_null (local.get $idx)) (then (br $done (ref.null any))))\n"
"      (if (ref.test (ref $LuaTable) (local.get $idx))\n"
"        (then\n"
"          (local.set $cur (ref.cast (ref $LuaTable) (local.get $idx)))\n"
"          (local.set $depth (i32.sub (local.get $depth) (i32.const 1)))\n"
"          (br_if $done (ref.null any)\n"
"            (i32.le_s (local.get $depth) (i32.const 0)))\n"
"          (br $lp)))\n"
"      (if (ref.test (ref $LuaClosure) (local.get $idx))\n"
"        (then (br $done\n"
"          (call $args_first (call $lua_call\n"
"            (ref.cast (ref $LuaClosure) (local.get $idx))\n"
"            (array.new_fixed $ArgArr 2 (local.get $cur) (local.get $k)))))))\n"
"      (br $done (ref.null any))\n"
"    )))\n"
"\n"
"  (func $get_metamethod (param $v anyref) (param $key (ref $LuaString)) (result anyref)\n"
"    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable))\n"
"    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v))) (then (return (ref.null any))))\n"
"    (local.set $t (ref.cast (ref $LuaTable) (local.get $v)))\n"
"    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))\n"
"    (if (ref.is_null (local.get $mt)) (then (return (ref.null any))))\n"
"    (call $tab_get_raw (ref.as_non_null (local.get $mt)) (local.get $key)))\n"
"\n"
"  (global $g_mkey_index (mut (ref null $LuaString)) (ref.null $LuaString))\n"
"  (global $g_mkey_add   (mut (ref null $LuaString)) (ref.null $LuaString))\n"
"  (global $g_mkey_eq    (mut (ref null $LuaString)) (ref.null $LuaString))\n"
"  (global $g_tab_str    (mut (ref null $LuaString)) (ref.null $LuaString))\n"
"  (global $g_empty_str  (mut (ref null $LuaString)) (ref.null $LuaString))\n"
"\n"
"  (func $tab_set (param $t (ref $LuaTable)) (param $k anyref) (param $v anyref)\n"
"    (local $i i32) (local $n i32) (local $cap i32)\n"
"    (local $keys (ref null $TArr)) (local $vals (ref null $TArr))\n"
"    (local.set $i (call $tab_find (local.get $t) (local.get $k)))\n"
"    (if (i32.ge_s (local.get $i) (i32.const 0))\n"
"      (then\n"
"        ;; existing key: update or delete\n"
"        (local.set $vals (struct.get $LuaTable $vals (local.get $t)))\n"
"        (if (ref.is_null (local.get $v))\n"
"          (then\n"
"            ;; delete: swap with last and shrink\n"
"            (local.set $n (i32.sub (struct.get $LuaTable $n (local.get $t)) (i32.const 1)))\n"
"            (local.set $keys (struct.get $LuaTable $keys (local.get $t)))\n"
"            (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $i)\n"
"              (array.get $TArr (ref.as_non_null (local.get $keys)) (local.get $n)))\n"
"            (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $i)\n"
"              (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $n)))\n"
"            (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $n) (ref.null any))\n"
"            (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $n) (ref.null any))\n"
"            (struct.set $LuaTable $n (local.get $t) (local.get $n)))\n"
"          (else\n"
"            (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $i) (local.get $v))))\n"
"        (return)))\n"
"    ;; not found: if value is nil, no-op; else append\n"
"    (if (ref.is_null (local.get $v)) (then (return)))\n"
"    (local.set $n (struct.get $LuaTable $n (local.get $t)))\n"
"    (local.set $cap (struct.get $LuaTable $cap (local.get $t)))\n"
"    (if (i32.ge_s (local.get $n) (local.get $cap))\n"
"      (then\n"
"        (call $tab_grow (local.get $t)\n"
"          (if (result i32) (i32.eqz (local.get $cap))\n"
"            (then (i32.const 4))\n"
"            (else (i32.mul (local.get $cap) (i32.const 2)))))))\n"
"    (local.set $keys (struct.get $LuaTable $keys (local.get $t)))\n"
"    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))\n"
"    (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $n) (local.get $k))\n"
"    (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $n) (local.get $v))\n"
"    (struct.set $LuaTable $n (local.get $t) (i32.add (local.get $n) (i32.const 1))))\n"
"\n"
"  ;; Length via array-border rule: count k=1,2,3,... while t[k] is non-nil.\n"
"  (func $tab_len (param $t (ref $LuaTable)) (result i32)\n"
"    (local $i i32) (local $k anyref)\n"
"    (local.set $i (i32.const 1))\n"
"    (block $done (loop $lp\n"
"      (local.set $k (call $tab_get (local.get $t) (ref.i31 (local.get $i))))\n"
"      (br_if $done (ref.is_null (local.get $k)))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (i32.sub (local.get $i) (i32.const 1)))\n"
"\n"
"  ;; --- numeric-for helper ---\n"
"  (func $for_step_positive (param $s anyref) (result i32)\n"
"    (if (result i32) (call $is_int (local.get $s))\n"
"      (then (i64.ge_s (call $as_int (local.get $s)) (i64.const 0)))\n"
"      (else (f64.ge (call $as_float (local.get $s)) (f64.const 0)))))\n"
"\n"
"  ;; --- closure dispatch + multi-value helpers + print builtin ---\n"
"  (func $lua_call (param $closure (ref $LuaClosure)) (param $args (ref $ArgArr))\n"
"                  (result (ref $ArgArr))\n"
"    (call_ref $LuaFn\n"
"      (local.get $closure)\n"
"      (local.get $args)\n"
"      (struct.get $LuaClosure $code (local.get $closure))))\n"
"\n"
"  (func $args_first (param $args (ref $ArgArr)) (result anyref)\n"
"    (if (result anyref) (i32.eqz (array.len (local.get $args)))\n"
"      (then (ref.null any))\n"
"      (else (array.get $ArgArr (local.get $args) (i32.const 0)))))\n"
"\n"
"  (func $args_at (param $args (ref $ArgArr)) (param $i i32) (result anyref)\n"
"    (if (result anyref) (i32.ge_u (local.get $i) (array.len (local.get $args)))\n"
"      (then (ref.null any))\n"
"      (else (array.get $ArgArr (local.get $args) (local.get $i)))))\n"
"\n"
"  (func $merge_args (param $a (ref $ArgArr)) (param $b (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $na i32) (local $nb i32) (local $out (ref $ArgArr))\n"
"    (local.set $na (array.len (local.get $a)))\n"
"    (local.set $nb (array.len (local.get $b)))\n"
"    (local.set $out (array.new $ArgArr (ref.null any)\n"
"                       (i32.add (local.get $na) (local.get $nb))))\n"
"    (array.copy $ArgArr $ArgArr\n"
"      (local.get $out) (i32.const 0)\n"
"      (local.get $a)   (i32.const 0) (local.get $na))\n"
"    (array.copy $ArgArr $ArgArr\n"
"      (local.get $out) (local.get $na)\n"
"      (local.get $b)   (i32.const 0) (local.get $nb))\n"
"    (local.get $out))\n"
"\n"
"  (tag $LuaError (param anyref))\n"
"\n"
"  ;; Real-Lua print: tostring each arg, join with TAB, host prints with a\n"
"  ;; trailing newline. Zero args -> just a newline.\n"
"  (func $builtin_print (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $n i32) (local $i i32) (local $acc anyref)\n"
"    (local.set $n (array.len (local.get $args)))\n"
"    (if (i32.eqz (local.get $n))\n"
"      (then\n"
"        (call $host_print (ref.as_non_null (global.get $g_empty_str)))\n"
"        (return (global.get $g_empty_args))))\n"
"    ;; Single arg: pass the raw value through so the host's value formatter\n"
"    ;; can render floats etc. without going through wasm-side tostring (which\n"
"    ;; currently returns the \"<float>\" placeholder for floats).\n"
"    (if (i32.eq (local.get $n) (i32.const 1))\n"
"      (then\n"
"        (call $host_print (call $args_at (local.get $args) (i32.const 0)))\n"
"        (return (global.get $g_empty_args))))\n"
"    ;; Multi-arg: stringify and join with TAB on the wasm side, then print.\n"
"    (local.set $acc (call $args_at (local.get $args) (i32.const 0)))\n"
"    (local.set $i (i32.const 1))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (local.set $acc\n"
"        (call $lua_concat\n"
"          (call $lua_concat (local.get $acc)\n"
"                            (ref.as_non_null (global.get $g_tab_str)))\n"
"          (call $args_at (local.get $args) (local.get $i))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (call $host_print (call $lua_tostring (local.get $acc)))\n"
"    (global.get $g_empty_args))\n"
"\n"
"  (func $builtin_error (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (throw $LuaError (call $args_at (local.get $args) (i32.const 0)))\n"
"    ;; unreachable, but typechecker needs a tail expression:\n"
"    (global.get $g_empty_args))\n"
"\n"
"  ;; pcall(f, ...): calls f with the remaining args. Returns (true, results...)\n"
"  ;; on success; (false, err) on caught $LuaError.\n"
"  (func $builtin_pcall (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $callee (ref $LuaClosure))\n"
"    (local $f_args (ref $ArgArr))\n"
"    (local $n_total i32) (local $n_fargs i32) (local $i i32)\n"
"    (local $err anyref) (local $results (ref $ArgArr)) (local $r2 (ref $ArgArr))\n"
"    (local.set $n_total (array.len (local.get $args)))\n"
"    (if (i32.eqz (local.get $n_total))\n"
"      (then (throw $LuaError (ref.null any))))\n"
"    (local.set $callee\n"
"      (ref.cast (ref $LuaClosure) (array.get $ArgArr (local.get $args) (i32.const 0))))\n"
"    (local.set $n_fargs (i32.sub (local.get $n_total) (i32.const 1)))\n"
"    (local.set $f_args (array.new $ArgArr (ref.null any) (local.get $n_fargs)))\n"
"    (block $copied (loop $cp\n"
"      (br_if $copied (i32.ge_s (local.get $i) (local.get $n_fargs)))\n"
"      (array.set $ArgArr (local.get $f_args) (local.get $i)\n"
"        (array.get $ArgArr (local.get $args)\n"
"          (i32.add (local.get $i) (i32.const 1))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $cp)))\n"
"    (block $catch_err (result anyref)\n"
"      ;; success path: build (true, results...) and return.\n"
"      (local.set $results\n"
"        (try_table (result (ref $ArgArr)) (catch $LuaError $catch_err)\n"
"          (call $lua_call (local.get $callee) (local.get $f_args))))\n"
"      ;; prepend true\n"
"      (local.set $r2 (array.new $ArgArr (ref.null any)\n"
"        (i32.add (array.len (local.get $results)) (i32.const 1))))\n"
"      (array.set $ArgArr (local.get $r2) (i32.const 0) (global.get $g_true))\n"
"      (array.copy $ArgArr $ArgArr (local.get $r2) (i32.const 1)\n"
"        (local.get $results) (i32.const 0) (array.len (local.get $results)))\n"
"      (return (local.get $r2)))\n"
"    ;; catch path: stack has the error anyref\n"
"    (local.set $err)\n"
"    (array.new_fixed $ArgArr 2 (global.get $g_false) (local.get $err)))\n"
"\n"
"  ;; --- additional top-level builtins ---\n"
"  (func $builtin_assert (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (if (call $lua_truthy (call $args_at (local.get $args) (i32.const 0)))\n"
"      (then (return (local.get $args))))\n"
"    ;; failed: throw the message (args[1]) or a default\n"
"    (throw $LuaError (call $args_at (local.get $args) (i32.const 1)))\n"
"    (global.get $g_empty_args))\n"
"\n"
"  ;; io.write — like print but no trailing newline, no tab between args\n"
"  (func $builtin_io_write (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $n i32) (local $i i32) (local $acc anyref)\n"
"    (local.set $n (array.len (local.get $args)))\n"
"    (if (i32.eqz (local.get $n)) (then (return (global.get $g_empty_args))))\n"
"    (if (i32.eq (local.get $n) (i32.const 1))\n"
"      (then\n"
"        (call $host_write_raw (call $args_at (local.get $args) (i32.const 0)))\n"
"        (return (global.get $g_empty_args))))\n"
"    (local.set $acc (call $args_at (local.get $args) (i32.const 0)))\n"
"    (local.set $i (i32.const 1))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (local.set $acc (call $lua_concat (local.get $acc)\n"
"                       (call $args_at (local.get $args) (local.get $i))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (call $host_write_raw (call $lua_tostring (local.get $acc)))\n"
"    (global.get $g_empty_args))\n"
"\n"
"  ;; io.read — single-line reader. Host writes the line into $fmt_buf and\n"
"  ;; returns its length; -1 means EOF, in which case we return nil.\n"
"  (func $builtin_io_read (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $n i32)\n"
"    (local.set $n (call $host_read))\n"
"    (if (i32.lt_s (local.get $n) (i32.const 0))\n"
"      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))\n"
"    (array.new_fixed $ArgArr 1 (call $fmt_buf_to_str (local.get $n))))\n"
"\n"
"  (func $builtin_type (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $v anyref) (local $bytes (ref null $LuaArr)) (local $b (ref null $LuaString))\n"
"    (local.set $v (call $args_at (local.get $args) (i32.const 0)))\n"
"    ;; pick canonical type-name bytes via existing $str_data offsets if any;\n"
"    ;; otherwise materialize on the fly. We just store the names inline.\n"
"    (if (ref.is_null (local.get $v))\n"
"      (then (local.set $bytes (call $bytes_of_lit (i32.const 19))))\n"     /* "nil" */
"      (else (if (ref.test (ref $LuaBool) (local.get $v))\n"
"        (then (local.set $bytes (call $bytes_of_lit (i32.const 7))))\n"   /* "boolean" */
"        (else (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))\n"
"          (then (local.set $bytes (call $bytes_of_lit (i32.const 0))))\n"  /* "number" */
"          (else (if (ref.test (ref $LuaString) (local.get $v))\n"
"            (then (local.set $bytes (call $bytes_of_lit (i32.const 1))))\n"  /* "string" */
"            (else (if (ref.test (ref $LuaTable) (local.get $v))\n"
"              (then (local.set $bytes (call $bytes_of_lit (i32.const 2))))\n"  /* "table" */
"              (else (local.set $bytes (call $bytes_of_lit (i32.const 3)))))))))))))\n"  /* "function" */
"    (local.set $b (struct.new $LuaString (ref.as_non_null (local.get $bytes))))\n"
"    (array.new_fixed $ArgArr 1 (ref.as_non_null (local.get $b))))\n"
"\n"
"  (func $builtin_tostring (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (array.new_fixed $ArgArr 1\n"
"      (call $lua_tostring (call $args_at (local.get $args) (i32.const 0)))))\n"
"\n"
"  ;; tonumber: numbers passthrough, strings parsed as ints (simple form),\n"
"  ;; everything else returns nil. (Phase-7 limitation.)\n"
"  (func $builtin_tonumber (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $v anyref) (local $bytes (ref $LuaArr))\n"
"    (local $n i32) (local $i i32) (local $acc i64) (local $neg i32) (local $b i32)\n"
"    (local.set $v (call $args_at (local.get $args) (i32.const 0)))\n"
"    (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))\n"
"      (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))\n"
"    (if (i32.eqz (ref.test (ref $LuaString) (local.get $v)))\n"
"      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))\n"
"    (local.set $bytes (struct.get $LuaString $bytes\n"
"                        (ref.cast (ref $LuaString) (local.get $v))))\n"
"    (local.set $n (array.len (local.get $bytes)))\n"
"    (if (i32.eqz (local.get $n))\n"
"      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))\n"
"    (if (i32.eq (array.get_u $LuaArr (local.get $bytes) (i32.const 0)) (i32.const 45))\n"
"      (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1))))\n"
"    (if (i32.ge_s (local.get $i) (local.get $n))\n"
"      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (local.set $b (array.get_u $LuaArr (local.get $bytes) (local.get $i)))\n"
"      (if (i32.or (i32.lt_s (local.get $b) (i32.const 48))\n"
"                  (i32.gt_s (local.get $b) (i32.const 57)))\n"
"        (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))\n"
"      (local.set $acc (i64.add (i64.mul (local.get $acc) (i64.const 10))\n"
"                                (i64.extend_i32_u\n"
"                                  (i32.sub (local.get $b) (i32.const 48)))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (if (local.get $neg)\n"
"      (then (local.set $acc (i64.sub (i64.const 0) (local.get $acc)))))\n"
"    (array.new_fixed $ArgArr 1 (call $make_int (local.get $acc))))\n"
"\n"
"  ;; next(t, k): returns next key/value pair, or nothing when exhausted.\n"
"  (func $builtin_next (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $t (ref $LuaTable)) (local $k anyref)\n"
"    (local $idx i32) (local $n i32)\n"
"    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))\n"
"    (local.set $k (call $args_at (local.get $args) (i32.const 1)))\n"
"    (if (ref.is_null (local.get $k))\n"
"      (then (local.set $idx (i32.const 0)))\n"
"      (else\n"
"        (local.set $idx (i32.add (call $tab_find (local.get $t) (local.get $k))\n"
"                                  (i32.const 1)))))\n"
"    (local.set $n (struct.get $LuaTable $n (local.get $t)))\n"
"    (if (i32.ge_s (local.get $idx) (local.get $n))\n"
"      (then (return (global.get $g_empty_args))))\n"
"    (array.new_fixed $ArgArr 2\n"
"      (array.get $TArr (ref.as_non_null (struct.get $LuaTable $keys (local.get $t)))\n"
"                       (local.get $idx))\n"
"      (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))\n"
"                       (local.get $idx))))\n"
"\n"
"  (func $builtin_pairs (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (array.new_fixed $ArgArr 3\n"
"      (global.get $g_builtin_next)\n"
"      (call $args_at (local.get $args) (i32.const 0))\n"
"      (ref.null any)))\n"
"\n"
"  ;; ipairs_iter: takes (t, prev_k) where prev_k is an int. Returns next int\n"
"  ;; key and t[next_k], or empty when t[next_k] is nil.\n"
"  (func $builtin_ipairs_iter (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $t (ref $LuaTable)) (local $k i32) (local $v anyref) (local $kref anyref)\n"
"    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))\n"
"    (local.set $k (i32.add\n"
"      (i31.get_s (ref.cast (ref i31) (call $args_at (local.get $args) (i32.const 1))))\n"
"      (i32.const 1)))\n"
"    (local.set $kref (ref.i31 (local.get $k)))\n"
"    (local.set $v (call $tab_get (local.get $t) (local.get $kref)))\n"
"    (if (ref.is_null (local.get $v))\n"
"      (then (return (global.get $g_empty_args))))\n"
"    (array.new_fixed $ArgArr 2 (local.get $kref) (local.get $v)))\n"
"\n"
"  (func $builtin_ipairs (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (array.new_fixed $ArgArr 3\n"
"      (global.get $g_builtin__ipairs_iter)\n"
"      (call $args_at (local.get $args) (i32.const 0))\n"
"      (ref.i31 (i32.const 0))))\n"
"\n"
"  (func $builtin_setmetatable (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $t (ref $LuaTable)) (local $mt anyref)\n"
"    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))\n"
"    (local.set $mt (call $args_at (local.get $args) (i32.const 1)))\n"
"    (if (ref.is_null (local.get $mt))\n"
"      (then (struct.set $LuaTable $meta (local.get $t) (ref.null $LuaTable)))\n"
"      (else (struct.set $LuaTable $meta (local.get $t)\n"
"        (ref.cast (ref $LuaTable) (local.get $mt)))))\n"
"    (array.new_fixed $ArgArr 1 (local.get $t)))\n"
"\n"
"  (func $builtin_getmetatable (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable))\n"
"    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))\n"
"    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))\n"
"    (if (ref.is_null (local.get $mt))\n"
"      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))\n"
"    (array.new_fixed $ArgArr 1 (ref.as_non_null (local.get $mt))))\n"
"\n"
"  ;; --- math library ---\n"
"  (func $builtin_math_floor (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $v anyref)\n"
"    (local.set $v (call $args_at (local.get $args) (i32.const 0)))\n"
"    (if (call $is_int (local.get $v))\n"
"      (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))\n"
"    (array.new_fixed $ArgArr 1\n"
"      (call $make_int (i64.trunc_f64_s (f64.floor (call $as_float (local.get $v)))))))\n"
"\n"
"  (func $builtin_math_abs (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $v anyref) (local $i i64)\n"
"    (local.set $v (call $args_at (local.get $args) (i32.const 0)))\n"
"    (if (call $is_int (local.get $v))\n"
"      (then\n"
"        (local.set $i (call $as_int (local.get $v)))\n"
"        (if (i64.lt_s (local.get $i) (i64.const 0))\n"
"          (then (local.set $i (i64.sub (i64.const 0) (local.get $i)))))\n"
"        (return (array.new_fixed $ArgArr 1 (call $make_int (local.get $i))))))\n"
"    (array.new_fixed $ArgArr 1\n"
"      (call $make_float (f64.abs (call $as_float (local.get $v))))))\n"
"\n"
"  (func $builtin_math_sqrt (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (array.new_fixed $ArgArr 1\n"
"      (call $make_float (f64.sqrt (call $as_float\n"
"        (call $args_at (local.get $args) (i32.const 0)))))))\n"
"\n"
"  ;; Transcendentals all route through host_math with a kind index.\n"
"  (func $math_via_host (param $kind i32) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (array.new_fixed $ArgArr 1\n"
"      (call $make_float (call $host_math (local.get $kind)\n"
"        (call $as_float (call $args_at (local.get $args) (i32.const 0)))))))\n"
"  (func $builtin_math_sin  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (call $math_via_host (i32.const 0) (local.get $args)))\n"
"  (func $builtin_math_cos  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (call $math_via_host (i32.const 1) (local.get $args)))\n"
"  (func $builtin_math_tan  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (call $math_via_host (i32.const 2) (local.get $args)))\n"
"  (func $builtin_math_asin (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (call $math_via_host (i32.const 3) (local.get $args)))\n"
"  (func $builtin_math_acos (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (call $math_via_host (i32.const 4) (local.get $args)))\n"
"  (func $builtin_math_atan (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (call $math_via_host (i32.const 5) (local.get $args)))\n"
"  (func $builtin_math_exp  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (call $math_via_host (i32.const 6) (local.get $args)))\n"
"  (func $builtin_math_log  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (call $math_via_host (i32.const 7) (local.get $args)))\n"
"\n"
"  (func $builtin_math_ceil (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $v anyref)\n"
"    (local.set $v (call $args_at (local.get $args) (i32.const 0)))\n"
"    (if (call $is_int (local.get $v))\n"
"      (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))\n"
"    (array.new_fixed $ArgArr 1\n"
"      (call $make_int (i64.trunc_f64_s (f64.ceil (call $as_float (local.get $v)))))))\n"
"\n"
"  ;; math.min/max: pick the smaller/larger of args[0..n-1] using $num_lt.\n"
"  (func $builtin_math_min (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $n i32) (local $i i32) (local $best anyref) (local $v anyref)\n"
"    (local.set $n (array.len (local.get $args)))\n"
"    (local.set $best (call $args_at (local.get $args) (i32.const 0)))\n"
"    (local.set $i (i32.const 1))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (local.set $v (call $args_at (local.get $args) (local.get $i)))\n"
"      (if (call $num_lt (local.get $v) (local.get $best))\n"
"        (then (local.set $best (local.get $v))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (array.new_fixed $ArgArr 1 (local.get $best)))\n"
"\n"
"  (func $builtin_math_max (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $n i32) (local $i i32) (local $best anyref) (local $v anyref)\n"
"    (local.set $n (array.len (local.get $args)))\n"
"    (local.set $best (call $args_at (local.get $args) (i32.const 0)))\n"
"    (local.set $i (i32.const 1))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (local.set $v (call $args_at (local.get $args) (local.get $i)))\n"
"      (if (call $num_lt (local.get $best) (local.get $v))\n"
"        (then (local.set $best (local.get $v))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (array.new_fixed $ArgArr 1 (local.get $best)))\n"
"\n"
"  ;; table.insert(t, v)         -> append at #t+1\n"
"  ;; table.insert(t, pos, v)    -> shift t[pos..#t] up, t[pos] = v\n"
"  (func $builtin_table_insert (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $t (ref $LuaTable)) (local $n i32) (local $pos i32) (local $v anyref)\n"
"    (local $i i32)\n"
"    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))\n"
"    (local.set $n (call $tab_len (local.get $t)))\n"
"    (if (i32.eq (array.len (local.get $args)) (i32.const 2))\n"
"      (then\n"
"        (local.set $v (call $args_at (local.get $args) (i32.const 1)))\n"
"        (call $tab_set (local.get $t) (ref.i31 (i32.add (local.get $n) (i32.const 1))) (local.get $v))\n"
"        (return (global.get $g_empty_args))))\n"
"    ;; 3-arg form\n"
"    (local.set $pos (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1)))))\n"
"    (local.set $v (call $args_at (local.get $args) (i32.const 2)))\n"
"    ;; shift elements pos..n up by 1\n"
"    (local.set $i (local.get $n))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.lt_s (local.get $i) (local.get $pos)))\n"
"      (call $tab_set (local.get $t)\n"
"        (ref.i31 (i32.add (local.get $i) (i32.const 1)))\n"
"        (call $tab_get (local.get $t) (ref.i31 (local.get $i))))\n"
"      (local.set $i (i32.sub (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (call $tab_set (local.get $t) (ref.i31 (local.get $pos)) (local.get $v))\n"
"    (global.get $g_empty_args))\n"
"\n"
"  ;; table.remove(t [, pos])    -> default pos = #t; returns removed value\n"
"  (func $builtin_table_remove (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $t (ref $LuaTable)) (local $n i32) (local $pos i32)\n"
"    (local $removed anyref) (local $i i32)\n"
"    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))\n"
"    (local.set $n (call $tab_len (local.get $t)))\n"
"    (if (i32.eqz (local.get $n))\n"
"      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))\n"
"    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))\n"
"      (then (local.set $pos\n"
"        (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1))))))\n"
"      (else (local.set $pos (local.get $n))))\n"
"    (local.set $removed (call $tab_get (local.get $t) (ref.i31 (local.get $pos))))\n"
"    ;; shift elements pos+1..n down by 1\n"
"    (local.set $i (local.get $pos))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (call $tab_set (local.get $t) (ref.i31 (local.get $i))\n"
"        (call $tab_get (local.get $t) (ref.i31 (i32.add (local.get $i) (i32.const 1)))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (call $tab_set (local.get $t) (ref.i31 (local.get $n)) (ref.null any))\n"
"    (array.new_fixed $ArgArr 1 (local.get $removed)))\n"
"\n"
"  ;; table.concat(t [, sep])    -> string concatenation of t[1..#t]\n"
"  (func $builtin_table_concat (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $t (ref $LuaTable)) (local $sep anyref) (local $acc anyref)\n"
"    (local $n i32) (local $i i32)\n"
"    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))\n"
"    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))\n"
"      (then (local.set $sep (call $args_at (local.get $args) (i32.const 1))))\n"
"      (else (local.set $sep (ref.as_non_null (global.get $g_empty_str)))))\n"
"    (local.set $n (call $tab_len (local.get $t)))\n"
"    (if (i32.eqz (local.get $n))\n"
"      (then (return (array.new_fixed $ArgArr 1 (ref.as_non_null (global.get $g_empty_str))))))\n"
"    (local.set $acc (call $tab_get (local.get $t) (ref.i31 (i32.const 1))))\n"
"    (local.set $i (i32.const 2))\n"
"    (block $done (loop $lp\n"
"      (br_if $done (i32.gt_s (local.get $i) (local.get $n)))\n"
"      (local.set $acc (call $lua_concat\n"
"        (call $lua_concat (local.get $acc) (local.get $sep))\n"
"        (call $tab_get (local.get $t) (ref.i31 (local.get $i)))))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (br $lp)))\n"
"    (array.new_fixed $ArgArr 1 (call $lua_tostring (local.get $acc))))\n"
"\n"
"  ;; --- string library ---\n"
"  (func $builtin_string_len (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (array.new_fixed $ArgArr 1 (call $lua_len\n"
"      (call $args_at (local.get $args) (i32.const 0)))))\n"
"\n"
"  ;; string.sub(s, i, [j])\n"
"  (func $builtin_string_sub (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $s (ref $LuaString)) (local $bytes (ref $LuaArr))\n"
"    (local $n i32) (local $i i32) (local $j i32) (local $len i32)\n"
"    (local $out (ref $LuaArr))\n"
"    (local.set $s (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0))))\n"
"    (local.set $bytes (struct.get $LuaString $bytes (local.get $s)))\n"
"    (local.set $n (array.len (local.get $bytes)))\n"
"    (local.set $i (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1)))))\n"
"    (local.set $j (local.get $n))\n"
"    (if (i32.gt_u (array.len (local.get $args)) (i32.const 2))\n"
"      (then\n"
"        (local.set $j (i32.wrap_i64\n"
"          (call $as_int (call $args_at (local.get $args) (i32.const 2)))))))\n"
"    (if (i32.lt_s (local.get $i) (i32.const 0))\n"
"      (then (local.set $i (i32.add (local.get $n) (i32.add (local.get $i) (i32.const 1))))))\n"
"    (if (i32.lt_s (local.get $j) (i32.const 0))\n"
"      (then (local.set $j (i32.add (local.get $n) (i32.add (local.get $j) (i32.const 1))))))\n"
"    (if (i32.lt_s (local.get $i) (i32.const 1)) (then (local.set $i (i32.const 1))))\n"
"    (if (i32.gt_s (local.get $j) (local.get $n)) (then (local.set $j (local.get $n))))\n"
"    (if (i32.gt_s (local.get $i) (local.get $j))\n"
"      (then (return (array.new_fixed $ArgArr 1\n"
"        (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0)))))))\n"
"    (local.set $len (i32.add (i32.sub (local.get $j) (local.get $i)) (i32.const 1)))\n"
"    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $len)))\n"
"    (array.copy $LuaArr $LuaArr\n"
"      (local.get $out)   (i32.const 0)\n"
"      (local.get $bytes) (i32.sub (local.get $i) (i32.const 1))\n"
"      (local.get $len))\n"
"    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out))))\n"
"\n"
"  ;; Builds a $LuaString from the first $n bytes of $fmt_buf.\n"
"  (func $fmt_buf_to_str (param $n i32) (result (ref $LuaString))\n"
"    (local $out (ref $LuaArr))\n"
"    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))\n"
"    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)\n"
"      (ref.as_non_null (global.get $fmt_buf)) (i32.const 0) (local.get $n))\n"
"    (struct.new $LuaString (local.get $out)))\n"
"\n"
"  ;; string.format(fmt, ...) — supports %s %d %x %g %f %e with optional .N\n"
"  ;; precision, plus %%. No width/flags.\n"
"  (func $builtin_string_format (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))\n"
"    (local $fmt (ref $LuaArr))\n"
"    (local $n i32) (local $i i32) (local $j i32)\n"
"    (local $acc anyref) (local $b i32) (local $conv i32) (local $prec i32)\n"
"    (local $arg_idx i32) (local $piece (ref $LuaArr))\n"
"    (local $arg anyref) (local $written i32)\n"
"    (local.set $fmt (struct.get $LuaString $bytes\n"
"      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))\n"
"    (local.set $n (array.len (local.get $fmt)))\n"
"    (local.set $acc (ref.as_non_null (global.get $g_empty_str)))\n"
"    (local.set $arg_idx (i32.const 1))\n"
"    (block $done (loop $main\n"
"      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))\n"
"      (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $i)))\n"
"      (if (i32.ne (local.get $b) (i32.const 37))     ;; not '%' -> collect run\n"
"        (then\n"
"          (local.set $j (i32.add (local.get $i) (i32.const 1)))\n"
"          (block $rdone (loop $rloop\n"
"            (br_if $rdone (i32.ge_s (local.get $j) (local.get $n)))\n"
"            (br_if $rdone (i32.eq (array.get_u $LuaArr (local.get $fmt) (local.get $j))\n"
"                                   (i32.const 37)))\n"
"            (local.set $j (i32.add (local.get $j) (i32.const 1)))\n"
"            (br $rloop)))\n"
"          (local.set $piece (array.new $LuaArr (i32.const 0)\n"
"                              (i32.sub (local.get $j) (local.get $i))))\n"
"          (array.copy $LuaArr $LuaArr (local.get $piece) (i32.const 0)\n"
"            (local.get $fmt) (local.get $i)\n"
"            (i32.sub (local.get $j) (local.get $i)))\n"
"          (local.set $acc (call $lua_concat (local.get $acc)\n"
"                            (struct.new $LuaString (local.get $piece))))\n"
"          (local.set $i (local.get $j))\n"
"          (br $main)))\n"
"      ;; here $b == '%'\n"
"      (if (i32.ge_s (i32.add (local.get $i) (i32.const 1)) (local.get $n))\n"
"        (then (br $done)))\n"
"      ;; %% -> literal %\n"
"      (if (i32.eq (array.get_u $LuaArr (local.get $fmt) (i32.add (local.get $i) (i32.const 1)))\n"
"                  (i32.const 37))\n"
"        (then\n"
"          (local.set $piece (array.new $LuaArr (i32.const 37) (i32.const 1)))\n"
"          (local.set $acc (call $lua_concat (local.get $acc)\n"
"                            (struct.new $LuaString (local.get $piece))))\n"
"          (local.set $i (i32.add (local.get $i) (i32.const 2)))\n"
"          (br $main)))\n"
"      ;; parse optional .NNN precision after the %\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (local.set $prec (i32.const -1))\n"
"      (if (i32.eq (array.get_u $LuaArr (local.get $fmt) (local.get $i)) (i32.const 46))\n"
"        (then\n"
"          (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"          (local.set $prec (i32.const 0))\n"
"          (block $pdone (loop $ploop\n"
"            (br_if $pdone (i32.ge_s (local.get $i) (local.get $n)))\n"
"            (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $i)))\n"
"            (br_if $pdone (i32.or (i32.lt_s (local.get $b) (i32.const 48))\n"
"                                   (i32.gt_s (local.get $b) (i32.const 57))))\n"
"            (local.set $prec\n"
"              (i32.add (i32.mul (local.get $prec) (i32.const 10))\n"
"                        (i32.sub (local.get $b) (i32.const 48))))\n"
"            (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"            (br $ploop)))))\n"
"      ;; conversion char\n"
"      (if (i32.ge_s (local.get $i) (local.get $n)) (then (br $done)))\n"
"      (local.set $conv (array.get_u $LuaArr (local.get $fmt) (local.get $i)))\n"
"      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n"
"      (local.set $arg (call $args_at (local.get $args) (local.get $arg_idx)))\n"
"      (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))\n"
"      ;; dispatch\n"
"      (if (i32.eq (local.get $conv) (i32.const 115))   ;; 's'\n"
"        (then\n"
"          (local.set $acc (call $lua_concat (local.get $acc)\n"
"                            (call $lua_tostring (local.get $arg))))\n"
"          (br $main)))\n"
"      (if (i32.eq (local.get $conv) (i32.const 100))   ;; 'd'\n"
"        (then\n"
"          (local.set $written (call $host_fmt (i32.const 0)\n"
"                                (call $as_int (local.get $arg)) (f64.const 0)\n"
"                                (local.get $prec)))\n"
"          (local.set $acc (call $lua_concat (local.get $acc)\n"
"                            (call $fmt_buf_to_str (local.get $written))))\n"
"          (br $main)))\n"
"      (if (i32.eq (local.get $conv) (i32.const 120))   ;; 'x'\n"
"        (then\n"
"          (local.set $written (call $host_fmt (i32.const 5)\n"
"                                (call $as_int (local.get $arg)) (f64.const 0)\n"
"                                (local.get $prec)))\n"
"          (local.set $acc (call $lua_concat (local.get $acc)\n"
"                            (call $fmt_buf_to_str (local.get $written))))\n"
"          (br $main)))\n"
"      (if (i32.eq (local.get $conv) (i32.const 103))   ;; 'g'\n"
"        (then\n"
"          (local.set $written (call $host_fmt (i32.const 2)\n"
"                                (i64.const 0) (call $as_float (local.get $arg))\n"
"                                (local.get $prec)))\n"
"          (local.set $acc (call $lua_concat (local.get $acc)\n"
"                            (call $fmt_buf_to_str (local.get $written))))\n"
"          (br $main)))\n"
"      (if (i32.eq (local.get $conv) (i32.const 102))   ;; 'f'\n"
"        (then\n"
"          (local.set $written (call $host_fmt (i32.const 3)\n"
"                                (i64.const 0) (call $as_float (local.get $arg))\n"
"                                (local.get $prec)))\n"
"          (local.set $acc (call $lua_concat (local.get $acc)\n"
"                            (call $fmt_buf_to_str (local.get $written))))\n"
"          (br $main)))\n"
"      (if (i32.eq (local.get $conv) (i32.const 101))   ;; 'e'\n"
"        (then\n"
"          (local.set $written (call $host_fmt (i32.const 4)\n"
"                                (i64.const 0) (call $as_float (local.get $arg))\n"
"                                (local.get $prec)))\n"
"          (local.set $acc (call $lua_concat (local.get $acc)\n"
"                            (call $fmt_buf_to_str (local.get $written))))\n"
"          (br $main)))\n"
"      ;; unknown conversion — just skip\n"
"      (br $main)))\n"
"    (array.new_fixed $ArgArr 1 (call $lua_tostring (local.get $acc))))\n"
"\n"
"  ;; bytes_of_lit: looks up a built-in literal name (`number`, `string`, etc.)\n"
"  ;; by index into the type-name slab. Indices into the slab:\n"
"  ;;   0  \"number\"     (6 bytes)\n"
"  ;;   1  \"string\"     (6 bytes)\n"
"  ;;   2  \"table\"      (5 bytes)\n"
"  ;;   3  \"function\"   (8 bytes)\n"
"  ;;   7  \"boolean\"    (7 bytes, overlaps the prefix region)\n"
"  ;;   19 \"nil\"        (3 bytes)\n"
"  ;;\n"
"  ;; The slab is the same `$str_data` segment used by $lua_tostring. We\n"
"  ;; carefully reserve names at known offsets in codegen_module.\n"
"  (func $bytes_of_lit (param $idx i32) (result (ref $LuaArr))\n"
"    (block $r (result (ref $LuaArr))\n"
"      (if (i32.eq (local.get $idx) (i32.const 0))\n"
"        (then (br $r (array.new_data $LuaArr $str_data (i32.const 19) (i32.const 6)))))\n"
"      (if (i32.eq (local.get $idx) (i32.const 1))\n"
"        (then (br $r (array.new_data $LuaArr $str_data (i32.const 25) (i32.const 6)))))\n"
"      (if (i32.eq (local.get $idx) (i32.const 2))\n"
"        (then (br $r (array.new_data $LuaArr $str_data (i32.const 31) (i32.const 5)))))\n"
"      (if (i32.eq (local.get $idx) (i32.const 3))\n"
"        (then (br $r (array.new_data $LuaArr $str_data (i32.const 36) (i32.const 8)))))\n"
"      (if (i32.eq (local.get $idx) (i32.const 7))\n"
"        (then (br $r (array.new_data $LuaArr $str_data (i32.const 44) (i32.const 7)))))\n"
"      (array.new_data $LuaArr $str_data (i32.const 0) (i32.const 3))))\n"
"\n"
"\n"
"  ;; --- exported decoders for the JS host ---\n"
"  (func (export \"lua_tag\") (param $v anyref) (result i32)\n"
"    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))\n"
"    (if (ref.test (ref $LuaBool)   (local.get $v)) (then (return (i32.const 1))))\n"
"    (if (call $is_int  (local.get $v))             (then (return (i32.const 2))))\n"
"    (if (call $is_float (local.get $v))            (then (return (i32.const 3))))\n"
"    (if (ref.test (ref $LuaString) (local.get $v)) (then (return (i32.const 4))))\n"
"    (if (ref.test (ref $LuaClosure) (local.get $v)) (then (return (i32.const 5))))\n"
"    (if (ref.test (ref $LuaTable) (local.get $v)) (then (return (i32.const 6))))\n"
"    (i32.const 99))\n"
"  (func (export \"lua_get_bool\") (param $v anyref) (result i32)\n"
"    (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v))))\n"
"  (func (export \"lua_get_int\") (param $v anyref) (result i64)\n"
"    (call $as_int (local.get $v)))\n"
"  (func (export \"lua_get_float\") (param $v anyref) (result f64)\n"
"    (call $as_float (local.get $v)))\n"
"  (func (export \"lua_str_len\") (param $v anyref) (result i32)\n"
"    (array.len (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $v)))))\n"
"  (func (export \"lua_str_byte\") (param $v anyref) (param $i i32) (result i32)\n"
"    (array.get_u $LuaArr\n"
"      (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $v)))\n"
"      (local.get $i)))\n"
"  ;; JS-side writer for the format scratch buffer.\n"
"  (func (export \"fmt_buf_set\") (param $i i32) (param $b i32)\n"
"    (array.set $LuaArr (ref.as_non_null (global.get $fmt_buf))\n"
"      (local.get $i) (local.get $b)))\n";

/* Reserved bytes of $str_data:
 *   0  nil(3)  3  true(4)  7  false(5)  12 <float>(7)
 *   19 number(6)  25 string(6)  31 table(5)  36 function(8)  44 boolean(7)
 *   51 __index(7)  58 __add(5)  63 __eq(4)  67 \t(1)  68 Lua 5.5(7) */
#define LITERAL_PREFIX "niltruefalse<float>numberstringtablefunctionboolean__index__add__eq\tLua 5.5"
#define LITERAL_PREFIX_LEN 75

/* Emit the body of one user function. */
static void emit_user_function(CG *c, const LuaFunc *fn) {
    WatBuilder *w = c->w;
    wat_appendf(w,
        "  (func $user_%d (type $LuaFn) "
        "(param $closure (ref $LuaClosure)) "
        "(param $args (ref $ArgArr)) (result (ref $ArgArr))\n",
        fn->func_idx);

    for (int i = 0; i < fn->n_locals; i++) {
        wat_appendf(w, "    (local $L%d (ref $Box))\n", i);
    }
    wat_append(w, "    (local $tmp_any anyref)\n");
    wat_append(w, "    (local $tmp_args (ref null $ArgArr))\n");
    wat_append(w, "    (local $tmp_clo (ref null $LuaClosure))\n");
    wat_append(w, "    (local $tmp_tab (ref null $LuaTable))\n");
    wat_append(w, "    (local $for_stop anyref)\n");
    wat_append(w, "    (local $for_step anyref)\n");
    wat_append(w, "    (local $for_iter_any anyref)\n");
    wat_append(w, "    (local $for_state anyref)\n");
    wat_append(w, "    (local $for_k anyref)\n");

    /* Param extraction: each declared parameter takes args[i] (nil if missing). */
    for (int i = 0; i < fn->n_params; i++) {
        wat_appendf(w,
            "    (local.set $L%d (struct.new $Box "
            "(call $args_at (local.get $args) (i32.const %d))))\n", i, i);
    }

    int was_in_main = c->in_main;
    c->in_main = 0;
    emit_block(c, &fn->body, 2);
    c->in_main = was_in_main;

    /* Default trailing return — empty results array. */
    wat_append(w, "    (global.get $g_empty_args)\n");
    wat_append(w, "  )\n");

    /* Declare so the funcref is usable in const init / closures. */
    wat_appendf(w, "  (elem declare func $user_%d)\n", fn->func_idx);
}

int codegen_module(const ParseResult *pr, WatBuilder *out,
                   char *err, size_t errlen) {
    CG c = { .w = out, .ok = 1, .in_main = 1 };
    strpool_add(&c.strs, LITERAL_PREFIX, LITERAL_PREFIX_LEN);

    wat_append(out, "(module\n");
    wat_append(out, PRELUDE_TYPES);
    wat_append(out, PRELUDE_HELPERS);

    /* elem declare for every builtin func, so ref.func works in const init. */
    wat_append(out, "\n  (elem declare func");
    int nb = builtin_count();
    for (int i = 0; i < nb; i++) {
        wat_appendf(out, " %s", builtin_func_name(i));
    }
    wat_append(out, ")\n");

    /* One $g_builtin_NAME wasm global per builtin, pre-wrapping a closure. */
    for (int i = 0; i < nb; i++) {
        wat_appendf(out,
            "  (global $g_builtin_%s (ref $LuaClosure)\n"
            "    (struct.new $LuaClosure (ref.func %s) (global.get $g_empty_upvals)))\n",
            builtin_name(i), builtin_func_name(i));
    }

    /* User-declared globals: one mutable anyref wasm global each. */
    if (pr->globals.count) {
        wat_append(out, "\n  ;; --- user globals ---\n");
        for (size_t i = 0; i < pr->globals.count; i++) {
            wat_appendf(out, "  (global $g_user_%zu (mut anyref) (ref.null any))\n", i);
        }
    }

    /* $stdlib_init: builds math/string tables from the library builtins
     * and assigns them to the corresponding $g_user_N slots. */
    wat_append(out, "\n  (func $stdlib_init (local $tab (ref $LuaTable))\n");
    /* Initialize metamethod-name globals + the tab and empty-string statics. */
    wat_append(out,
        "    (global.set $g_mkey_index\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const 51) (i32.const 7))))\n"
        "    (global.set $g_mkey_add\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const 58) (i32.const 5))))\n"
        "    (global.set $g_mkey_eq\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const 63) (i32.const 4))))\n"
        "    (global.set $g_tab_str\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const 67) (i32.const 1))))\n"
        "    (global.set $g_empty_str\n"
        "      (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0))))\n"
        "    (global.set $fmt_buf\n"
        "      (array.new $LuaArr (i32.const 0) (i32.const 1024)))\n");
    /* Library-table globals + the _VERSION constant. */
    for (size_t gi = 0; gi < pr->globals.count; gi++) {
        const char *gname = pr->globals.items[gi].name;
        size_t glen = pr->globals.items[gi].name_len;
        /* _VERSION is a plain string global, not a library table. */
        if (glen == 8 && memcmp(gname, "_VERSION", 8) == 0) {
            wat_appendf(out,
                "    (global.set $g_user_%zu\n"
                "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "        (i32.const 68) (i32.const 7))))\n", gi);
            continue;
        }
        BuiltinClass cls;
        if      (glen == 4 && memcmp(gname, "math",   4) == 0) cls = BLT_LIB_MATH;
        else if (glen == 6 && memcmp(gname, "string", 6) == 0) cls = BLT_LIB_STRING;
        else if (glen == 2 && memcmp(gname, "io",     2) == 0) cls = BLT_LIB_IO;
        else if (glen == 5 && memcmp(gname, "table",  5) == 0) cls = BLT_LIB_TABLE;
        else continue;
        wat_append(out, "    (local.set $tab (call $tab_new))\n");
        for (int bi = 0; bi < nb; bi++) {
            if (builtin_class(bi) != cls) continue;
            const char *key = builtin_lib_key(bi);
            size_t key_len = strlen(key);
            StrRef sr = strpool_add(&c.strs, key, key_len);
            wat_appendf(out,
                "    (call $tab_set (local.get $tab)\n"
                "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "        (i32.const %zu) (i32.const %zu)))\n"
                "      (global.get $g_builtin_%s))\n",
                sr.offset, sr.len, builtin_name(bi));
        }
        /* Plain-value constants for the math library. */
        if (cls == BLT_LIB_MATH) {
            StrRef pi_key = strpool_add(&c.strs, "pi", 2);
            wat_appendf(out,
                "    (call $tab_set (local.get $tab)\n"
                "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "        (i32.const %zu) (i32.const %zu)))\n"
                "      (struct.new $LuaFloat (f64.const 3.141592653589793)))\n",
                pi_key.offset, pi_key.len);
            StrRef huge_key = strpool_add(&c.strs, "huge", 4);
            wat_appendf(out,
                "    (call $tab_set (local.get $tab)\n"
                "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "        (i32.const %zu) (i32.const %zu)))\n"
                "      (struct.new $LuaFloat (f64.const inf)))\n",
                huge_key.offset, huge_key.len);
        }
        wat_appendf(out, "    (global.set $g_user_%zu (local.get $tab))\n", gi);
    }
    wat_append(out, "  )\n");

    wat_append(out, "\n  ;; --- user functions ---\n");

    for (size_t i = 0; i < pr->funcs.count; i++) {
        emit_user_function(&c, pr->funcs.items[i]);
        if (!c.ok) break;
    }

    if (c.ok) {
        wat_append(out, "\n  ;; --- main (top-level chunk) ---\n");
        wat_append(out, "  (func $main (export \"main\")\n");
        for (int i = 0; i < pr->main_n_locals; i++) {
            wat_appendf(out, "    (local $L%d (ref $Box))\n", i);
        }
        wat_append(out, "    (local $tmp_any anyref)\n");
        wat_append(out, "    (local $tmp_args (ref null $ArgArr))\n");
        wat_append(out, "    (local $tmp_clo (ref null $LuaClosure))\n");
        wat_append(out, "    (local $tmp_tab (ref null $LuaTable))\n");
        wat_append(out, "    (local $for_stop anyref)\n");
        wat_append(out, "    (local $for_step anyref)\n");
        wat_append(out, "    (local $for_iter_any anyref)\n");
        wat_append(out, "    (local $for_state anyref)\n");
        wat_append(out, "    (local $for_k anyref)\n");
        wat_append(out, "    (call $stdlib_init)\n");

        emit_block(&c, &pr->main_body, 2);

        wat_append(out, "  )\n");
    }

    /* Data segment */
    wat_append(out, "  (data $str_data \"");
    for (size_t i = 0; i < c.strs.used; i++) {
        unsigned char b = (unsigned char)c.strs.bytes[i];
        if (b == '"' || b == '\\') wat_appendf(out, "\\%02x", b);
        else if (b >= 0x20 && b < 0x7f) {
            char tmp[2] = { (char)b, 0 };
            wat_append(out, tmp);
        } else {
            wat_appendf(out, "\\%02x", b);
        }
    }
    wat_append(out, "\")\n");

    wat_append(out, ")\n");

    if (!c.ok) {
        snprintf(err, errlen, "%s", c.err);
        free(c.strs.bytes);
        return 0;
    }
    free(c.strs.bytes);
    return 1;
}
