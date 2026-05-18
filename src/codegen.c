#include "codegen.h"
#include "builtins.h"
#include "xalloc.h"
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
        p->bytes = xrealloc(p->bytes, new_cap);
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
    /* Escape-analysis context for the currently-emitted body: cur_captured[s]
     * != 0 means slot s must be heap-boxed (some descendant function captures
     * it); cur_captured[s] == 0 lets the slot be a plain wasm anyref. Set
     * before emitting either a user function body or the main chunk. */
    const unsigned char *cur_captured;
    int cur_n_locals;
    char err[256];
    int ok;
} CG;

/* True iff the local at this slot index must be allocated as a $Box. */
static int slot_is_boxed(const CG *c, int slot) {
    if (slot < 0 || slot >= c->cur_n_locals) return 1; /* defensive */
    return c->cur_captured ? c->cur_captured[slot] : 1;
}

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
            if (slot_is_boxed(c, idx)) {
                wat_appendf(c->w, "(struct.get $Box $v (local.get $L%d))\n", idx);
            } else {
                wat_appendf(c->w, "(local.get $L%d)\n", idx);
            }
            break;
        case VAR_UPVAL:
            wat_appendf(c->w,
                "(struct.get $Box $v (array.get $UpvalArr "
                "(struct.get $LuaClosure $upvals (local.get $closure)) "
                "(i32.const %d)))\n", idx);
            break;
        case VAR_BUILTIN:
            /* Use the unique WAT func name (sans leading $) so library
             * builtins like `math.type` don't collide with top-level `type`. */
            wat_appendf(c->w, "(global.get $g_%s)\n", builtin_func_name(idx) + 1);
            break;
        case VAR_GLOBAL:
            wat_appendf(c->w, "(global.get $g_user_%d)\n", idx);
            break;
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
                if (slot_is_boxed(c, t->as.var.idx)) {
                    emit_indent(c, depth); wat_append(c->w, "(struct.set $Box $v\n");
                    emit_box_ref(c, VAR_LOCAL, t->as.var.idx, depth + 1);
                } else {
                    emit_indent(c, depth);
                    wat_appendf(c->w, "(local.set $L%d\n", t->as.var.idx);
                }
                break;
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

/* An expression whose value in a multi-value position is a full $ArgArr
 * (call/method-call/vararg) rather than a single anyref. */
static int is_multival_tail(const Expr *e) {
    return e->kind == EXPR_CALL ||
           e->kind == EXPR_METHOD_CALL ||
           e->kind == EXPR_VARARG;
}

/* Emit (ref $ArgArr) for a multi-value expression (last-in-list context). */
static void emit_call_array(CG *c, const Expr *e, int depth);
static void emit_multival_array(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_VARARG) {
        emit_indent(c, depth);
        wat_append(c->w, "(local.get $varargs)\n");
        return;
    }
    emit_call_array(c, e, depth);
}

/* Build a (ref $ArgArr) from a sequence of argument expressions, splicing
 * the trailing expression's full multi-value result if it is a call or `...`. */
static void emit_args_array(CG *c, Expr **args, size_t nargs, int depth) {
    if (nargs == 0) {
        emit_indent(c, depth); wat_append(c->w, "(global.get $g_empty_args)\n");
        return;
    }
    int last_mv = is_multival_tail(args[nargs - 1]);
    if (!last_mv) {
        emit_indent(c, depth);
        wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", nargs);
        for (size_t i = 0; i < nargs; i++) emit_expr(c, args[i], depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    size_t singles = nargs - 1;
    emit_indent(c, depth); wat_append(c->w, "(call $merge_args\n");
    if (singles == 0) {
        emit_indent(c, depth + 1); wat_append(c->w, "(global.get $g_empty_args)\n");
    } else {
        emit_indent(c, depth + 1);
        wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", singles);
        for (size_t i = 0; i < singles; i++) emit_expr(c, args[i], depth + 2);
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    }
    emit_multival_array(c, args[nargs - 1], depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
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
        emit_indent(c, depth); wat_append(c->w, "(call $lua_call_any\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(call $tab_get\n");
        emit_indent(c, depth + 2); wat_append(c->w, "(ref.cast (ref $LuaTable) (local.get $tmp_any))\n");
        emit_indent(c, depth + 2);
        wat_appendf(c->w,
            "(struct.new $LuaString (array.new_data $LuaArr $str_data "
            "(i32.const %zu) (i32.const %zu)))\n", sr.offset, sr.len);
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
        /* args = [recv] ++ method args */
        size_t mna = e->as.method_call.nargs;
        int has_mv = mna > 0 && is_multival_tail(e->as.method_call.args[mna - 1]);
        emit_indent(c, depth + 1); wat_append(c->w, "(call $merge_args\n");
        emit_indent(c, depth + 2);
        wat_append(c->w, "(array.new_fixed $ArgArr 1 (local.get $tmp_any))\n");
        if (mna == 0) {
            emit_indent(c, depth + 2); wat_append(c->w, "(global.get $g_empty_args)\n");
        } else if (!has_mv) {
            emit_indent(c, depth + 2);
            wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", mna);
            for (size_t i = 0; i < mna; i++) emit_expr(c, e->as.method_call.args[i], depth + 3);
            emit_indent(c, depth + 2); wat_append(c->w, ")\n");
        } else {
            emit_args_array(c, e->as.method_call.args, mna, depth + 2);
        }
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    emit_indent(c, depth); wat_append(c->w, "(call $lua_call_any\n");
    emit_expr(c, e->as.call.callee, depth + 1);
    emit_args_array(c, e->as.call.args, e->as.call.nargs, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* In expression context we want a single anyref; wrap with $args_first. */
static void emit_call(CG *c, const Expr *e, int depth) {
    emit_indent(c, depth); wat_append(c->w, "(call $args_first\n");
    emit_call_array(c, e, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* Tail call: `return f(args)` lowers to a return_call_ref so deep
 * recursion doesn't grow the wasm call stack. Fast path: if the callee
 * really is a closure, use return_call_ref. Slow path: fall through to
 * $lua_call_any (which walks __call metamethods and throws a typed
 * error for non-callables); TCO is lost in that case, which is fine
 * for a metamethod hop. */
static void emit_tail_call(CG *c, const Expr *e, int depth) {
    /* Stash callee and args once. */
    emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_any\n");
    emit_expr(c, e->as.call.callee, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
    emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
    emit_args_array(c, e->as.call.args, e->as.call.nargs, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
    /* Fast path: real closure -> return_call_ref. */
    emit_indent(c, depth);
    wat_append(c->w, "(if (ref.test (ref $LuaClosure) (local.get $tmp_any))\n");
    emit_indent(c, depth + 1); wat_append(c->w, "(then\n");
    emit_indent(c, depth + 2);
    wat_append(c->w, "(local.set $tmp_clo (ref.cast (ref $LuaClosure) (local.get $tmp_any)))\n");
    emit_indent(c, depth + 2); wat_append(c->w, "(return_call_ref $LuaFn\n");
    emit_indent(c, depth + 3);
    wat_append(c->w, "(ref.as_non_null (local.get $tmp_clo))\n");
    emit_indent(c, depth + 3);
    wat_append(c->w, "(ref.as_non_null (local.get $tmp_args))\n");
    emit_indent(c, depth + 3);
    wat_append(c->w, "(struct.get $LuaClosure $code (ref.as_non_null (local.get $tmp_clo))))))\n");
    /* Slow path: __call walk / typed error. */
    emit_indent(c, depth);
    wat_append(c->w,
        "(return (call $lua_call_any (local.get $tmp_any) "
        "(ref.as_non_null (local.get $tmp_args))))\n");
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
    /* If the final entry is positional AND a multi-value tail (call/vararg),
     * we splice all of its values rather than just taking the first. */
    int splice_last = (n > 0 &&
                       e->as.table_ctor.entries[n - 1].kind == TENT_POSITIONAL &&
                       is_multival_tail(e->as.table_ctor.entries[n - 1].value));
    int last_normal = splice_last ? n - 1 : n;
    for (int i = 0; i < last_normal; i++) {
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
    if (splice_last) {
        /* (call $tab_append_args (local.tee $tmp_tab) (i32.const pos_idx) <args>) */
        emit_indent(c, depth + 1); wat_append(c->w, "local.tee $tmp_tab\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(call $tab_append_args\n");
        emit_indent(c, depth + 2); wat_append(c->w, "(ref.as_non_null (local.get $tmp_tab))\n");
        emit_indent(c, depth + 2); wat_appendf(c->w, "(i32.const %d)\n", pos_idx);
        emit_multival_array(c, e->as.table_ctor.entries[n - 1].value, depth + 2);
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
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
        case EXPR_VARARG:
            emit_indent(c, depth);
            wat_append(c->w,
                "(call $args_first (local.get $varargs))\n");
            break;
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
                             is_multival_tail(s->as.local.values[n_values - 1]));
            if (last_call) {
                emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
                emit_multival_array(c, s->as.local.values[n_values - 1], depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            for (int i = 0; i < n_names; i++) {
                int slot = s->as.local.local_idxs[i];
                int boxed = slot_is_boxed(c, slot);
                emit_indent(c, depth);
                if (boxed) {
                    wat_appendf(c->w, "(local.set $L%d (struct.new $Box\n", slot);
                } else {
                    wat_appendf(c->w, "(local.set $L%d\n", slot);
                }
                if (n_values == 0) {
                    emit_indent(c, depth + 1); wat_append(c->w, "(ref.null any)\n");
                } else {
                    emit_distributed_value(c, i, n_values, s->as.local.values,
                                           last_call, depth + 1);
                }
                emit_indent(c, depth);
                wat_append(c->w, boxed ? "))\n" : ")\n");
            }
            break;
        }

        case STMT_ASSIGN: {
            int n_targets = s->as.assign.n_targets;
            int n_values = s->as.assign.n_values;
            int last_call = (n_values > 0 &&
                             is_multival_tail(s->as.assign.values[n_values - 1]));
            if (n_targets == 1) {
                AssignTarget *t = &s->as.assign.targets[0];
                emit_target_open(c, t, depth);
                if (last_call) {
                    emit_indent(c, depth + 1); wat_append(c->w, "(call $args_first\n");
                    emit_multival_array(c, s->as.assign.values[0], depth + 2);
                    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
                } else {
                    emit_expr(c, s->as.assign.values[0], depth + 1);
                }
                emit_target_close(c, t, depth);
                break;
            }
            /* Multi-target: must evaluate ALL RHS before assigning (Lua spec).
             * Build the full args array in $tmp_args, then distribute. */
            (void)last_call;
            emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
            emit_args_array(c, s->as.assign.values, n_values, depth + 1);
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
            /* `return f(), x, ...` and similar: build the result array. A lone
             * multi-value tail (a single call/vararg) returns its array as-is. */
            if (n_values == 1 && is_multival_tail(s->as.return_stmt.values[0])) {
                emit_multival_array(c, s->as.return_stmt.values[0], depth);
            } else {
                emit_args_array(c, s->as.return_stmt.values, n_values, depth);
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
            int boxed = slot_is_boxed(c, slot);
            /* Initialize the control variable with `start`, and stash
             * stop/step in scratch locals. */
            emit_indent(c, depth);
            if (boxed) {
                wat_appendf(c->w, "(local.set $L%d (struct.new $Box\n", slot);
            } else {
                wat_appendf(c->w, "(local.set $L%d\n", slot);
            }
            emit_expr(c, s->as.for_num.start, depth + 1);
            emit_indent(c, depth); wat_append(c->w, boxed ? "))\n" : ")\n");
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
            emit_indent(c, depth);
            wat_append(c->w, "(call $for_check_step (local.get $for_step))\n");

            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            /* terminate? */
            emit_indent(c, depth + 2);
            wat_append(c->w,
                "(if (call $for_step_positive (local.get $for_step))\n");
            emit_indent(c, depth + 2); wat_append(c->w, "  (then\n");
            const char *load_i  = boxed ? "(struct.get $Box $v (local.get $L%d))"
                                        : "(local.get $L%d)";
            char load_buf[80];
            snprintf(load_buf, sizeof(load_buf), load_i, slot);
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "    (br_if $brk_%d (i32.eqz (call $num_le\n"
                "      %s\n"
                "      (local.get $for_stop)))))\n", label, load_buf);
            emit_indent(c, depth + 2); wat_append(c->w, "  (else\n");
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "    (br_if $brk_%d (i32.eqz (call $num_le\n"
                "      (local.get $for_stop)\n"
                "      %s)))))\n", label, load_buf);
            /* body */
            emit_block(c, &s->as.for_num.body, depth + 2);
            /* i = i + step */
            emit_indent(c, depth + 2);
            if (boxed) {
                wat_appendf(c->w,
                    "(struct.set $Box $v (local.get $L%d) "
                    "(call $lua_add (struct.get $Box $v (local.get $L%d)) "
                    "(local.get $for_step)))\n", slot, slot);
            } else {
                wat_appendf(c->w,
                    "(local.set $L%d (call $lua_add (local.get $L%d) "
                    "(local.get $for_step)))\n", slot, slot);
            }
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
            emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
            emit_args_array(c, s->as.for_gen.exprs, n_exprs, depth + 1);
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

            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            /* Call iter(state, k). The iterator can be any callable (a
             * closure, or a table with __call) — go through $lua_call_any
             * so a wrong type produces a typed error instead of a trap. */
            emit_indent(c, depth + 2); wat_append(c->w, "(local.set $tmp_args\n");
            emit_indent(c, depth + 3); wat_append(c->w, "(call $lua_call_any\n");
            emit_indent(c, depth + 4); wat_append(c->w, "(local.get $for_iter_any)\n");
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
                int li = s->as.for_gen.local_idxs[i];
                emit_indent(c, depth + 2);
                if (slot_is_boxed(c, li)) {
                    wat_appendf(c->w,
                        "(struct.set $Box $v (local.get $L%d) "
                        "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                        "(i32.const %d)))\n", li, i);
                } else {
                    wat_appendf(c->w,
                        "(local.set $L%d "
                        "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                        "(i32.const %d)))\n", li, i);
                }
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
                             is_multival_tail(s->as.global_decl.values[n_values - 1]));
            if (last_call) {
                emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
                emit_multival_array(c, s->as.global_decl.values[n_values - 1], depth + 1);
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
            int slot = s->as.local_func.local_idx;
            int boxed = slot_is_boxed(c, slot);
            /* If the slot is captured (e.g. by the closure itself for
             * recursion), pre-allocate the box with nil so the function body
             * can see its own slot; then store the closure into the box.
             * If not captured, simply build the closure and store it. */
            if (boxed) {
                emit_indent(c, depth);
                wat_appendf(c->w,
                    "(local.set $L%d (struct.new $Box (ref.null any)))\n", slot);
                emit_indent(c, depth); wat_append(c->w, "(struct.set $Box $v\n");
                emit_indent(c, depth + 1);
                wat_appendf(c->w, "(local.get $L%d)\n", slot);
                emit_function_expr(c, s->as.local_func.func, depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            } else {
                emit_indent(c, depth);
                wat_appendf(c->w, "(local.set $L%d\n", slot);
                emit_function_expr(c, s->as.local_func.func, depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
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

static const char PRELUDE[] = {
#embed "prelude.wat"
, '\0'
};

/* Reserved bytes of $str_data:
 *   0  nil(3)  3  true(4)  7  false(5)  12 <float>(7)
 *   19 number(6)  25 string(6)  31 table(5)  36 function(8)  44 boolean(7)
 *   51 __index(7)  58 __add(5)  63 __eq(4)  67 \t(1)  68 Lua 5.5(7) */
/* Reserved bytes added after the historical prefix:
 *   75, len 18: "'for' step is zero"             (used by $for_check_step)
 *   93, len 36: "attempt to call a non-function value"  ($lua_call_any)
 *  129, len  6: "__call"                         ($g_mkey_call) */
#define LITERAL_PREFIX "niltruefalse<float>numberstringtablefunctionboolean__index__add__eq\tLua 5.5'for' step is zeroattempt to call a non-function value__call"
#define LITERAL_PREFIX_LEN 135

/* Emit the body of one user function. */
static void emit_user_function(CG *c, const LuaFunc *fn) {
    WatBuilder *w = c->w;
    wat_appendf(w,
        "  (func $user_%d (type $LuaFn) "
        "(param $closure (ref $LuaClosure)) "
        "(param $args (ref $ArgArr)) (result (ref $ArgArr))\n",
        fn->func_idx);

    /* Wire escape-analysis state for this body. */
    const unsigned char *prev_captured = c->cur_captured;
    int prev_n_locals = c->cur_n_locals;
    c->cur_captured = fn->captured;
    c->cur_n_locals = fn->n_locals;

    for (int i = 0; i < fn->n_locals; i++) {
        if (fn->captured && fn->captured[i]) {
            wat_appendf(w, "    (local $L%d (ref $Box))\n", i);
        } else {
            wat_appendf(w, "    (local $L%d anyref)\n", i);
        }
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
    if (fn->is_vararg) {
        /* Non-null: prologue always writes $varargs before first use. */
        wat_append(w, "    (local $varargs (ref $ArgArr))\n");
    }

    /* Param extraction: each declared parameter takes args[i] (nil if missing). */
    for (int i = 0; i < fn->n_params; i++) {
        if (fn->captured && fn->captured[i]) {
            wat_appendf(w,
                "    (local.set $L%d (struct.new $Box "
                "(call $args_at (local.get $args) (i32.const %d))))\n", i, i);
        } else {
            wat_appendf(w,
                "    (local.set $L%d "
                "(call $args_at (local.get $args) (i32.const %d)))\n", i, i);
        }
    }
    if (fn->is_vararg) {
        wat_appendf(w,
            "    (local.set $varargs (call $args_slice "
            "(local.get $args) (i32.const %d)))\n", fn->n_params);
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

    c->cur_captured = prev_captured;
    c->cur_n_locals = prev_n_locals;
}

int codegen_module(const ParseResult *pr, WatBuilder *out,
                   char *err, size_t errlen) {
    CG c = { .w = out, .ok = 1, .in_main = 1 };
    strpool_add(&c.strs, LITERAL_PREFIX, LITERAL_PREFIX_LEN);

    wat_append(out, "(module\n");
    wat_append(out, PRELUDE);

    /* elem declare for every builtin func, so ref.func works in const init. */
    wat_append(out, "\n  (elem declare func");
    int nb = builtin_count();
    for (int i = 0; i < nb; i++) {
        wat_appendf(out, " %s", builtin_func_name(i));
    }
    wat_append(out, ")\n");

    /* One wasm global per builtin, pre-wrapping a closure. The global
     * name mirrors the WAT func name (sans $), so library builtins
     * (e.g. $builtin_math_type) don't collide with top-level ones
     * (e.g. $builtin_type) that happen to share a Lua-visible name. */
    for (int i = 0; i < nb; i++) {
        wat_appendf(out,
            "  (global $g_%s (ref $LuaClosure)\n"
            "    (struct.new $LuaClosure (ref.func %s) (global.get $g_empty_upvals)))\n",
            builtin_func_name(i) + 1, builtin_func_name(i));
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
        "    (global.set $g_mkey_call\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const 129) (i32.const 6))))\n"
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
        else if (glen == 4 && memcmp(gname, "utf8",   4) == 0) cls = BLT_LIB_UTF8;
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
                "      (global.get $g_%s))\n",
                sr.offset, sr.len, builtin_func_name(bi) + 1);
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
            StrRef maxi_key = strpool_add(&c.strs, "maxinteger", 10);
            wat_appendf(out,
                "    (call $tab_set (local.get $tab)\n"
                "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "        (i32.const %zu) (i32.const %zu)))\n"
                "      (call $make_int (i64.const 9223372036854775807)))\n",
                maxi_key.offset, maxi_key.len);
            StrRef mini_key = strpool_add(&c.strs, "mininteger", 10);
            wat_appendf(out,
                "    (call $tab_set (local.get $tab)\n"
                "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "        (i32.const %zu) (i32.const %zu)))\n"
                "      (call $make_int (i64.const -9223372036854775808)))\n",
                mini_key.offset, mini_key.len);
        }
        /* utf8.charpattern: the Lua-pattern string that matches one
         * UTF-8 codepoint. Binary content; strpool_add and data-segment
         * escaping handle the non-printable bytes. */
        if (cls == BLT_LIB_UTF8) {
            StrRef cp_key = strpool_add(&c.strs, "charpattern", 11);
            static const char CHARPAT[] =
                "[\x00-\x7F\xC2-\xFD][\x80-\xBF]*";
            StrRef cp_val = strpool_add(&c.strs, CHARPAT, sizeof(CHARPAT) - 1);
            wat_appendf(out,
                "    (call $tab_set (local.get $tab)\n"
                "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "        (i32.const %zu) (i32.const %zu)))\n"
                "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "        (i32.const %zu) (i32.const %zu))))\n",
                cp_key.offset, cp_key.len,
                cp_val.offset, cp_val.len);
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
        c.cur_captured = pr->main_captured;
        c.cur_n_locals = pr->main_n_locals;
        for (int i = 0; i < pr->main_n_locals; i++) {
            if (pr->main_captured && pr->main_captured[i]) {
                wat_appendf(out, "    (local $L%d (ref $Box))\n", i);
            } else {
                wat_appendf(out, "    (local $L%d anyref)\n", i);
            }
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
