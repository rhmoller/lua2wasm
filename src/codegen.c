#include "codegen.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================
 * Codegen v2.
 *
 * Value representation (all Lua values are `anyref`):
 *   nil      -> (ref.null any)
 *   false    -> global $g_false   : (ref $LuaBool) struct{ i32 0 }
 *   true     -> global $g_true    : (ref $LuaBool) struct{ i32 1 }
 *   int      -> i31ref if value fits in i31 (signed 30-bit-ish range),
 *               else (struct.new $LuaInt (i64 value))
 *   float    -> (struct.new $LuaFloat (f64 value))
 *   string   -> (struct.new $LuaString (array of bytes))
 *
 * String literals are concatenated into a single data segment; each
 * literal produces an (array.new_data $LuaArr $str_data offset len) call.
 *
 * JS-side `print` decodes values via exported helpers:
 *   lua_tag(v) -> 0=nil 1=bool 2=int 3=float 4=string
 *   lua_get_bool(v), lua_get_int(v), lua_get_float(v)
 *   lua_str_len(v), lua_str_byte(v, i)
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
    char err[256];
    int ok;
} CG;

static void cg_error(CG *c, const char *msg) {
    if (!c->ok) return;
    c->ok = 0;
    snprintf(c->err, sizeof(c->err), "codegen: %s", msg);
}

/* ----- emission helpers ----- */
static void emit_indent(CG *c, int depth) {
    for (int i = 0; i < depth; i++) wat_append(c->w, "  ");
}

/* Fits in signed i31 range? */
static int i31_fits(int64_t v) {
    return v >= -(int64_t)0x40000000 && v < (int64_t)0x40000000;
}

/* ----- expression emission -----
 * Every expression leaves one `anyref` on the stack.
 */
static void emit_expr(CG *c, const Expr *e, int depth);
static void emit_block(CG *c, const Block *b, int depth);

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
    /* %a is hex-float: lossless. */
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
        default:         return "$lua_add"; /* and/or handled separately */
    }
}

static void emit_binop(CG *c, const Expr *e, int depth) {
    BinOp op = e->as.binop.op;
    if (op == BIN_AND || op == BIN_OR) {
        /* Short-circuit, Lua semantics:
         *   a and b -> if truthy(a) then b else a
         *   a or  b -> if truthy(a) then a else b
         * Store lhs in $tmp_any, then branch on its truthiness.
         */
        int label = c->next_label++;
        emit_indent(c, depth);
        wat_appendf(c->w, "(block $sc_%d (result anyref)\n", label);

        emit_expr(c, e->as.binop.lhs, depth + 1);
        emit_indent(c, depth + 1); wat_append(c->w, "local.set $tmp_any\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(call $lua_truthy (local.get $tmp_any))\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(if (then\n");
        if (op == BIN_AND) {
            /* truthy -> evaluate rhs, that's the result */
            emit_expr(c, e->as.binop.rhs, depth + 2);
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $sc_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            /* falsy fallthrough: push tmp_any */
            emit_indent(c, depth + 1); wat_append(c->w, "local.get $tmp_any\n");
        } else {
            /* OR: truthy -> push tmp_any */
            emit_indent(c, depth + 2); wat_append(c->w, "local.get $tmp_any\n");
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $sc_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            /* falsy fallthrough: evaluate rhs */
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

static void emit_call(CG *c, const Expr *e, int produces_value, int depth) {
    const Expr *callee = e->as.call.callee;
    if (callee->kind != EXPR_VAR || callee->as.var.local_idx != -2) {
        cg_error(c, "v2 only supports calling the builtin `print`");
        return;
    }
    if (e->as.call.nargs != 1) {
        cg_error(c, "v2 print takes exactly 1 argument");
        return;
    }
    emit_expr(c, e->as.call.args[0], depth);
    emit_indent(c, depth);
    wat_append(c->w, "(call $host_print)\n");
    /* host_print returns no value. If the call was used as an expression,
     * push nil so the value rep is consistent. */
    if (produces_value) {
        emit_indent(c, depth);
        wat_append(c->w, "(ref.null any)\n");
    }
}

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
        case EXPR_VAR:
            emit_indent(c, depth);
            wat_appendf(c->w, "(local.get $L%d)\n", e->as.var.local_idx);
            break;
        case EXPR_CALL:   emit_call(c, e, /*produces_value*/1, depth); break;
        case EXPR_BINOP:  emit_binop(c, e, depth); break;
        case EXPR_UNOP:   emit_unop(c, e, depth); break;
    }
}

/* ----- statements ----- */
static void emit_stmt(CG *c, const Stmt *s, int depth) {
    if (!c->ok) return;
    switch (s->kind) {
        case STMT_LOCAL:
            if (s->as.local.init) emit_expr(c, s->as.local.init, depth);
            else { emit_indent(c, depth); wat_append(c->w, "(ref.null any)\n"); }
            emit_indent(c, depth);
            wat_appendf(c->w, "(local.set $L%d)\n", s->as.local.local_idx);
            break;
        case STMT_ASSIGN:
            emit_expr(c, s->as.assign.value, depth);
            emit_indent(c, depth);
            wat_appendf(c->w, "(local.set $L%d)\n", s->as.assign.local_idx);
            break;
        case STMT_EXPR:
            /* Must be a call. Bare call as statement produces no value. */
            if (s->as.expr_stmt.expr->kind == EXPR_CALL) {
                emit_call(c, s->as.expr_stmt.expr, /*produces_value*/0, depth);
            } else {
                emit_expr(c, s->as.expr_stmt.expr, depth);
                emit_indent(c, depth); wat_append(c->w, "drop\n");
            }
            break;
        case STMT_DO:
            emit_block(c, &s->as.do_stmt.body, depth);
            break;
        case STMT_RETURN:
            emit_indent(c, depth); wat_append(c->w, "return\n");
            break;
        case STMT_WHILE: {
            int label = c->next_label++;
            emit_indent(c, depth);
            wat_appendf(c->w, "(block $while_break_%d\n", label);
            emit_indent(c, depth + 1);
            wat_appendf(c->w, "(loop $while_cont_%d\n", label);
            emit_expr(c, s->as.while_stmt.cond, depth + 2);
            emit_indent(c, depth + 2);
            wat_append(c->w, "(call $lua_truthy)\n");
            emit_indent(c, depth + 2);
            wat_append(c->w, "i32.eqz\n");
            emit_indent(c, depth + 2);
            wat_appendf(c->w, "br_if $while_break_%d\n", label);
            emit_block(c, &s->as.while_stmt.body, depth + 2);
            emit_indent(c, depth + 2);
            wat_appendf(c->w, "br $while_cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            break;
        }
        case STMT_IF: {
            /* Emit nested if/else chain. */
            int label = c->next_label++;
            emit_indent(c, depth);
            wat_appendf(c->w, "(block $if_end_%d\n", label);
            for (size_t i = 0; i < s->as.if_stmt.narms; i++) {
                IfArm *a = &s->as.if_stmt.arms[i];
                emit_expr(c, a->cond, depth + 1);
                emit_indent(c, depth + 1); wat_append(c->w, "(call $lua_truthy)\n");
                emit_indent(c, depth + 1);
                wat_append(c->w, "(if (then\n");
                emit_block(c, &a->body, depth + 2);
                emit_indent(c, depth + 2);
                wat_appendf(c->w, "br $if_end_%d\n", label);
                emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            }
            if (s->as.if_stmt.has_else) {
                emit_block(c, &s->as.if_stmt.else_body, depth + 1);
            }
            emit_indent(c, depth);
            wat_append(c->w, ")\n");
            break;
        }
    }
}

static void emit_block(CG *c, const Block *b, int depth) {
    for (size_t i = 0; i < b->count; i++) emit_stmt(c, b->items[i], depth);
}

/* ============================================================
 * Static prelude: type definitions, runtime helpers, globals.
 * ============================================================ */
static const char *PRELUDE_TYPES =
"  ;; --- type definitions ---\n"
"  (type $LuaArr    (array (mut i8)))\n"
"  (type $LuaString (sub (struct (field $bytes (ref $LuaArr)))))\n"
"  (type $LuaFloat  (sub (struct (field $v f64))))\n"
"  (type $LuaInt    (sub (struct (field $v i64))))\n"
"  (type $LuaBool   (sub (struct (field $b i32))))\n"
"\n"
"  (import \"host\" \"print\" (func $host_print (param anyref)))\n"
"\n"
"  ;; --- global singletons for booleans ---\n"
"  (global $g_true  (ref $LuaBool) (struct.new $LuaBool (i32.const 1)))\n"
"  (global $g_false (ref $LuaBool) (struct.new $LuaBool (i32.const 0)))\n";

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
"  ;; --- arithmetic: if both operands int -> int; else float ---\n"
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
"  ;; // floor division: int if both ints, else floor of float\n"
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
"  ;; ^ always returns float\n"
"  (func $lua_pow (param $a anyref) (param $b anyref) (result anyref)\n"
"    (local $base f64) (local $exp f64) (local $r f64) (local $i i32)\n"
"    ;; Crude integer-exponent fast path; otherwise return 0.0 (v2 stub).\n"
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
"    ;; v2: only strings supported (tables in v3)\n"
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
"    ;; nil == nil\n"
"    (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))\n"
"      (then (return (i32.const 1))))\n"
"    (if (i32.or  (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))\n"
"      (then (return (i32.const 0))))\n"
"    ;; booleans\n"
"    (if (i32.and (ref.test (ref $LuaBool) (local.get $a))\n"
"                 (ref.test (ref $LuaBool) (local.get $b)))\n"
"      (then (return (i32.eq\n"
"        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $a)))\n"
"        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $b)))))))\n"
"    ;; numbers (int or float, freely mixing)\n"
"    (if (i32.and\n"
"          (i32.or (call $is_int (local.get $a)) (call $is_float (local.get $a)))\n"
"          (i32.or (call $is_int (local.get $b)) (call $is_float (local.get $b))))\n"
"      (then (return (call $num_eq (local.get $a) (local.get $b)))))\n"
"    ;; strings\n"
"    (if (i32.and (ref.test (ref $LuaString) (local.get $a))\n"
"                 (ref.test (ref $LuaString) (local.get $b)))\n"
"      (then (return (call $str_eq (local.get $a) (local.get $b)))))\n"
"    ;; otherwise: identity (ref.eq) - but anyref doesn't directly support; default false\n"
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
"  ;; int-to-bytes implemented in WASM (no host callback needed).\n"
"  (func $int_to_bytes (param $v i64) (result (ref $LuaArr))\n"
"    (local $neg i32)\n"
"    (local $tmp (ref $LuaArr)) (local $n i32)\n"
"    (local $out (ref $LuaArr))\n"
"    (local $i i32) (local $j i32) (local $d i32) (local $total i32)\n"
"    (if (i64.lt_s (local.get $v) (i64.const 0))\n"
"      (then\n"
"        (local.set $neg (i32.const 1))\n"
"        (local.set $v (i64.sub (i64.const 0) (local.get $v)))))\n"
"    ;; up to 20 decimal digits for i64; allocate scratch of 21\n"
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
"  ;; Float-to-bytes is non-trivial; v2 stub returns \"<float>\".\n"
"  (func $float_stub_bytes (result (ref $LuaArr))\n"
"    (array.new_data $LuaArr $str_data (i32.const 12) (i32.const 7)))\n"
"\n"
"  (func $lua_tostring (param $v anyref) (result (ref $LuaString))\n"
"    (if (result (ref $LuaString)) (ref.is_null (local.get $v))\n"
"      (then (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
"               (i32.const 0) (i32.const 3))))   ;; \"nil\" lives at offset 0\n"
"      (else (if (result (ref $LuaString)) (ref.test (ref $LuaBool) (local.get $v))\n"
"        (then (if (result (ref $LuaString))\n"
"                  (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v)))\n"
"          (then (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
"                  (i32.const 3) (i32.const 4))))   ;; \"true\"\n"
"          (else (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
"                  (i32.const 7) (i32.const 5)))))) ;; \"false\"\n"
"        (else (if (result (ref $LuaString)) (ref.test (ref $LuaString) (local.get $v))\n"
"          (then (ref.cast (ref $LuaString) (local.get $v)))\n"
"          (else (if (result (ref $LuaString)) (call $is_int (local.get $v))\n"
"            (then (struct.new $LuaString (call $int_to_bytes (call $as_int (local.get $v)))))\n"
"            (else (struct.new $LuaString (call $float_stub_bytes)))))))))))\n"
"\n"
"  (func $lua_concat (param $a anyref) (param $b anyref) (result anyref)\n"
"    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr)) (local $out (ref $LuaArr))\n"
"    (local $na i32) (local $nb i32) (local $i i32)\n"
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
"  ;; --- exported decoders for the JS host ---\n"
"  (func (export \"lua_tag\") (param $v anyref) (result i32)\n"
"    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))\n"
"    (if (ref.test (ref $LuaBool)   (local.get $v)) (then (return (i32.const 1))))\n"
"    (if (call $is_int  (local.get $v))             (then (return (i32.const 2))))\n"
"    (if (call $is_float (local.get $v))            (then (return (i32.const 3))))\n"
"    (if (ref.test (ref $LuaString) (local.get $v)) (then (return (i32.const 4))))\n"
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

/* The first bytes of the data segment are reserved for built-in literals
 * used by $lua_tostring:
 *   offset  0  len 3   "nil"
 *   offset  3  len 4   "true"
 *   offset  7  len 5   "false"
 *   offset 12  len 7   "<float>"  (v2 placeholder for float-to-string) */
#define LITERAL_PREFIX "niltruefalse<float>"
#define LITERAL_PREFIX_LEN 19

int codegen_module(const ParseResult *pr, WatBuilder *out,
                   char *err, size_t errlen) {
    CG c = { .w = out, .ok = 1 };

    /* Reserve "niltruefalse" at offsets 0..11 for $lua_tostring. */
    strpool_add(&c.strs, LITERAL_PREFIX, LITERAL_PREFIX_LEN);

    wat_append(out, "(module\n");
    wat_append(out, PRELUDE_TYPES);
    wat_append(out, PRELUDE_HELPERS);
    wat_append(out, "\n  ;; --- main ---\n");
    wat_append(out, "  (func $main (export \"main\")\n");
    /* declare locals */
    for (int i = 0; i < pr->max_locals; i++) {
        wat_appendf(out, "    (local $L%d anyref)\n", i);
    }
    wat_append(out, "    (local $tmp_any anyref)\n");

    emit_block(&c, &pr->program, 2);

    wat_append(out, "  )\n");
    /* Note: we deliberately do NOT use `(start)`. The host calls `main`
     * after instantiation so that wasm exports are visible to JS imports
     * (which is critical for `print`'s value-decoding callbacks). */

    /* Data segment with collected string bytes. */
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
