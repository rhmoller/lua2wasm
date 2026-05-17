#include "codegen.h"
#include <stdio.h>
#include <string.h>

/*
 * v1 codegen strategy
 * -------------------
 * Every Lua expression compiles to a sequence of instructions leaving exactly
 * one `anyref` on the WASM stack.
 *
 *  - Integer literals N: produce (ref.i31 (i32.const N)) when N fits in i31.
 *  - BinOp +,-,*,/      : recurse, then call helper $lua_add / $lua_sub / ...
 *                         which take (anyref, anyref) -> anyref.
 *  - Call f(args...)    : evaluate args, then call helper $lua_call_<N>
 *                         imported from the runtime. For v1 we only support
 *                         calling the global `print`, which is a host import
 *                         that takes one anyref.
 *
 * Identifier resolution in v1 is trivial: the only identifier we recognise is
 * `print`, which lowers to a direct call of the imported $host_print function.
 *
 * The emitted module imports:
 *   (import "host" "print" (func $host_print (param anyref)))
 *
 * and defines helper $lua_add etc inline (pure i31 arithmetic for v1).
 */

static int emit_expr(const LuaNode *n, WatBuilder *w, char *err, size_t errlen);

static int fail(char *err, size_t errlen, const char *msg) {
    snprintf(err, errlen, "codegen: %s", msg);
    return 0;
}

static int emit_number(const LuaNode *n, WatBuilder *w, char *err, size_t errlen) {
    int64_t v = n->as.number.value;
    if (v < -(int64_t)0x40000000 || v >= (int64_t)0x40000000) {
        return fail(err, errlen, "integer literal out of i31 range (v1 limit)");
    }
    wat_appendf(w, "    (ref.i31 (i32.const %lld))\n", (long long)v);
    return 1;
}

static const char *binop_helper(LuaBinOp op) {
    switch (op) {
        case BINOP_ADD: return "$lua_add";
        case BINOP_SUB: return "$lua_sub";
        case BINOP_MUL: return "$lua_mul";
        case BINOP_DIV: return "$lua_div";
    }
    return "$lua_add";
}

static int emit_binop(const LuaNode *n, WatBuilder *w, char *err, size_t errlen) {
    if (!emit_expr(n->as.binop.lhs, w, err, errlen)) return 0;
    if (!emit_expr(n->as.binop.rhs, w, err, errlen)) return 0;
    wat_appendf(w, "    (call %s)\n", binop_helper(n->as.binop.op));
    return 1;
}

static int ident_is(const LuaNode *n, const char *name) {
    size_t nl = strlen(name);
    return n->kind == NODE_IDENT && n->as.ident.len == nl &&
           memcmp(n->as.ident.name, name, nl) == 0;
}

static int emit_call(const LuaNode *n, WatBuilder *w, char *err, size_t errlen) {
    const LuaNode *callee = n->as.call.callee;
    if (!ident_is(callee, "print")) {
        return fail(err, errlen, "v1 only supports calling `print`");
    }
    if (n->as.call.nargs != 1) {
        return fail(err, errlen, "v1 print takes exactly 1 argument");
    }
    if (!emit_expr(n->as.call.args[0], w, err, errlen)) return 0;
    wat_append(w, "    (call $host_print)\n");
    /* print returns nothing; for an expression-statement we drop nothing. */
    /* But our model says every expression leaves one anyref. To keep
     * statements simple we treat top-level calls as statements (no value). */
    return 1;
}

static int emit_ident(const LuaNode *n, WatBuilder *w, char *err, size_t errlen) {
    (void)w;
    char buf[128];
    snprintf(buf, sizeof(buf), "v1 cannot use identifier `%.*s` as a value",
             (int)n->as.ident.len, n->as.ident.name);
    return fail(err, errlen, buf);
}

static int emit_expr(const LuaNode *n, WatBuilder *w, char *err, size_t errlen) {
    switch (n->kind) {
        case NODE_NUMBER: return emit_number(n, w, err, errlen);
        case NODE_BINOP:  return emit_binop(n, w, err, errlen);
        case NODE_CALL:   return emit_call(n, w, err, errlen);
        case NODE_IDENT:  return emit_ident(n, w, err, errlen);
    }
    return fail(err, errlen, "unknown node kind");
}

static const char *PRELUDE =
"(module\n"
"  (import \"host\" \"print\" (func $host_print (param anyref)))\n"
"\n"
"  ;; v1 arithmetic helpers: assume both operands are i31ref-tagged ints.\n"
"  ;; Result is also tagged as i31ref. Overflow is not checked in v1.\n"
"  (func $lua_add (param $a anyref) (param $b anyref) (result anyref)\n"
"    (ref.i31\n"
"      (i32.add\n"
"        (i31.get_s (ref.cast (ref i31) (local.get $a)))\n"
"        (i31.get_s (ref.cast (ref i31) (local.get $b))))))\n"
"\n"
"  (func $lua_sub (param $a anyref) (param $b anyref) (result anyref)\n"
"    (ref.i31\n"
"      (i32.sub\n"
"        (i31.get_s (ref.cast (ref i31) (local.get $a)))\n"
"        (i31.get_s (ref.cast (ref i31) (local.get $b))))))\n"
"\n"
"  (func $lua_mul (param $a anyref) (param $b anyref) (result anyref)\n"
"    (ref.i31\n"
"      (i32.mul\n"
"        (i31.get_s (ref.cast (ref i31) (local.get $a)))\n"
"        (i31.get_s (ref.cast (ref i31) (local.get $b))))))\n"
"\n"
"  (func $lua_div (param $a anyref) (param $b anyref) (result anyref)\n"
"    (ref.i31\n"
"      (i32.div_s\n"
"        (i31.get_s (ref.cast (ref i31) (local.get $a)))\n"
"        (i31.get_s (ref.cast (ref i31) (local.get $b))))))\n"
"\n"
"  (func $main (export \"main\")\n";

static const char *EPILOGUE =
"  )\n"
"  (start $main)\n"
")\n";

int codegen_module(const Program *prog, WatBuilder *out, char *err, size_t errlen) {
    wat_append(out, PRELUDE);
    for (size_t i = 0; i < prog->count; i++) {
        const LuaNode *s = prog->items[i];
        if (s->kind == NODE_CALL) {
            if (!emit_call(s, out, err, errlen)) return 0;
        } else {
            /* Expression-statement that produces a value: drop it.
             * (Real Lua disallows this, but accepting it makes the
             * v1 surface easier to test.) */
            if (!emit_expr(s, out, err, errlen)) return 0;
            wat_append(out, "    drop\n");
        }
    }
    wat_append(out, EPILOGUE);
    return 1;
}
