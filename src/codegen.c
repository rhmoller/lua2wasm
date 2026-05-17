#include "codegen.h"
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
        case VAR_BUILTIN_PRINT:
            wat_append(c->w, "(global.get $g_print)\n");
            break;
    }
}

/* Emit code that pushes the (ref $Box) for the named binding (not its value).
 * Used to: (a) write to it via struct.set, or (b) capture it into an upvalue
 * array of a child closure. */
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
        case VAR_BUILTIN_PRINT:
            cg_error(c, "cannot take a box reference to a builtin");
            break;
    }
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

/* ----- function call (uniform; no special-casing of print) ----- */
static void emit_call(CG *c, const Expr *e, int depth) {
    emit_indent(c, depth); wat_append(c->w, "(call $lua_call\n");
    /* callee: any anyref, but $lua_call expects (ref $LuaClosure). */
    emit_indent(c, depth + 1); wat_append(c->w, "(ref.cast (ref $LuaClosure)\n");
    emit_expr(c, e->as.call.callee, depth + 2);
    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    /* args array */
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
    }
}

/* ----- statements ----- */
static void emit_stmt(CG *c, const Stmt *s, int depth) {
    if (!c->ok) return;
    switch (s->kind) {
        case STMT_LOCAL:
            emit_indent(c, depth);
            wat_appendf(c->w, "(local.set $L%d (struct.new $Box\n", s->as.local.local_idx);
            if (s->as.local.init) emit_expr(c, s->as.local.init, depth + 1);
            else { emit_indent(c, depth + 1); wat_append(c->w, "(ref.null any)\n"); }
            emit_indent(c, depth); wat_append(c->w, "))\n");
            break;

        case STMT_ASSIGN:
            /* (struct.set $Box $v <boxref> <value>) */
            emit_indent(c, depth); wat_append(c->w, "(struct.set $Box $v\n");
            emit_box_ref(c, s->as.assign.kind, s->as.assign.idx, depth + 1);
            emit_expr(c, s->as.assign.value, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            break;

        case STMT_EXPR:
            /* Expression-statement is always a call. Discard result. */
            emit_call(c, s->as.expr_stmt.expr, depth);
            emit_indent(c, depth); wat_append(c->w, "drop\n");
            break;

        case STMT_DO:
            emit_block(c, &s->as.do_stmt.body, depth);
            break;

        case STMT_RETURN:
            if (c->in_main) {
                /* main has no return value; ignore any expression. */
                emit_indent(c, depth); wat_append(c->w, "return\n");
            } else {
                if (s->as.return_stmt.value) emit_expr(c, s->as.return_stmt.value, depth);
                else { emit_indent(c, depth); wat_append(c->w, "(ref.null any)\n"); }
                emit_indent(c, depth); wat_append(c->w, "return\n");
            }
            break;

        case STMT_WHILE: {
            int label = c->next_label++;
            emit_indent(c, depth); wat_appendf(c->w, "(block $while_break_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $while_cont_%d\n", label);
            emit_expr(c, s->as.while_stmt.cond, depth + 2);
            emit_indent(c, depth + 2); wat_append(c->w, "(call $lua_truthy)\n");
            emit_indent(c, depth + 2); wat_append(c->w, "i32.eqz\n");
            emit_indent(c, depth + 2); wat_appendf(c->w, "br_if $while_break_%d\n", label);
            emit_block(c, &s->as.while_stmt.body, depth + 2);
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $while_cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
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
"                       (result anyref))))\n"
"\n"
"  (import \"host\" \"print\" (func $host_print (param anyref)))\n"
"\n"
"  ;; --- singletons ---\n"
"  (global $g_true  (ref $LuaBool) (struct.new $LuaBool (i32.const 1)))\n"
"  (global $g_false (ref $LuaBool) (struct.new $LuaBool (i32.const 0)))\n"
"  (global $g_empty_upvals (ref $UpvalArr) (array.new_fixed $UpvalArr 0))\n";

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
"  (func $lua_add (param $a anyref) (param $b anyref) (result anyref)\n"
"    (if (result anyref)\n"
"      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))\n"
"      (then (call $make_int (i64.add (call $as_int (local.get $a))\n"
"                                     (call $as_int (local.get $b)))))\n"
"      (else (call $make_float (f64.add (call $as_float (local.get $a))\n"
"                                       (call $as_float (local.get $b)))))))\n"
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
"    (call $make_int\n"
"      (i64.extend_i32_u\n"
"        (array.len (struct.get $LuaString $bytes\n"
"          (ref.cast (ref $LuaString) (local.get $a)))))))\n"
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
"  (func $float_stub_bytes (result (ref $LuaArr))\n"
"    (array.new_data $LuaArr $str_data (i32.const 12) (i32.const 7)))\n"
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
"            (else (struct.new $LuaString (call $float_stub_bytes)))))))))))\n"
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
"  ;; --- closure dispatch + print builtin ---\n"
"  (func $lua_call (param $closure (ref $LuaClosure)) (param $args (ref $ArgArr)) (result anyref)\n"
"    (call_ref $LuaFn\n"
"      (local.get $closure)\n"
"      (local.get $args)\n"
"      (struct.get $LuaClosure $code (local.get $closure))))\n"
"\n"
"  (func $builtin_print (type $LuaFn)\n"
"    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result anyref)\n"
"    (call $host_print (array.get $ArgArr (local.get $args) (i32.const 0)))\n"
"    (ref.null any))\n"
"\n"
"  (elem declare func $builtin_print)\n"
"  (global $g_print (ref $LuaClosure)\n"
"    (struct.new $LuaClosure\n"
"      (ref.func $builtin_print)\n"
"      (global.get $g_empty_upvals)))\n"
"\n"
"  ;; --- exported decoders for the JS host ---\n"
"  (func (export \"lua_tag\") (param $v anyref) (result i32)\n"
"    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))\n"
"    (if (ref.test (ref $LuaBool)   (local.get $v)) (then (return (i32.const 1))))\n"
"    (if (call $is_int  (local.get $v))             (then (return (i32.const 2))))\n"
"    (if (call $is_float (local.get $v))            (then (return (i32.const 3))))\n"
"    (if (ref.test (ref $LuaString) (local.get $v)) (then (return (i32.const 4))))\n"
"    (if (ref.test (ref $LuaClosure) (local.get $v)) (then (return (i32.const 5))))\n"
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
"      (local.get $i)))\n";

#define LITERAL_PREFIX "niltruefalse<float>"
#define LITERAL_PREFIX_LEN 19

/* Emit the body of one user function. */
static void emit_user_function(CG *c, const LuaFunc *fn) {
    WatBuilder *w = c->w;
    wat_appendf(w,
        "  (func $user_%d (type $LuaFn) "
        "(param $closure (ref $LuaClosure)) "
        "(param $args (ref $ArgArr)) (result anyref)\n",
        fn->func_idx);

    for (int i = 0; i < fn->n_locals; i++) {
        wat_appendf(w, "    (local $L%d (ref $Box))\n", i);
    }
    wat_append(w, "    (local $tmp_any anyref)\n");

    /* Param extraction: box each arg into its local slot. */
    for (int i = 0; i < fn->n_params; i++) {
        wat_appendf(w,
            "    (local.set $L%d (struct.new $Box "
            "(array.get $ArgArr (local.get $args) (i32.const %d))))\n", i, i);
    }

    int was_in_main = c->in_main;
    c->in_main = 0;
    emit_block(c, &fn->body, 2);
    c->in_main = was_in_main;

    /* Default trailing return (nil) so the function is well-typed even if
     * the body has no explicit return on every path. */
    wat_append(w, "    (ref.null any)\n");
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
