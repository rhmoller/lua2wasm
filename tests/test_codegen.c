#include "../src/codegen.h"
#include "../src/lexer.h"
#include "../src/parser.h"
#include "../src/wat_builder.h"
#include "../third_party/munit/munit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static MunitResult test_emits_expected(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(1+2)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);

    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, "test", 0, 1, 0, &w, err, sizeof(err)); /* opt=1 (default) */
    if (!ok) munit_logf(MUNIT_LOG_ERROR, "codegen: %s", err);
    munit_assert_true(ok);

    const char *s = wat_cstr(&w);
    munit_assert_not_null(strstr(s, "(import \"host\" \"print\""));
    /* With numeric specialization on by default, the constant int add `1+2` is
     * lowered to unboxed i64 arithmetic, so the boxed forms ($lua_add and the
     * `ref.i31` operands) are ABSENT from the emitted code. They don't occur in
     * the prelude either, so checking for their absence is a clean signal that
     * the default really specialized. The boxed shape is pinned separately by
     * test_emits_boxed_fallback_o0. */
    munit_assert_null(strstr(s, "(ref.i31 (i32.const 1))"));
    munit_assert_null(strstr(s, "(call $lua_add)"));
    /* No direct $host_print call from user code; goes through $lua_call. */
    munit_assert_not_null(strstr(s, "(call $lua_call"));
    munit_assert_not_null(strstr(s, "(global.get $g_builtin_print)"));
    munit_assert_not_null(strstr(s, "(func $main (export \"main\")"));
    munit_assert_not_null(strstr(s, "(type $LuaClosure"));

    wat_free(&w);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* -O0 is the proven boxed fallback: every Lua value is a host-GC object and
 * arithmetic goes through generic $lua_add dispatch. Pin that lowering so the
 * fallback can't silently rot now that specialization is the default. */
static MunitResult test_emits_boxed_fallback_o0(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(1+2)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);

    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, "test", 0, 0, 0, &w, err, sizeof(err)); /* opt=0 */
    if (!ok) munit_logf(MUNIT_LOG_ERROR, "codegen: %s", err);
    munit_assert_true(ok);

    const char *s = wat_cstr(&w);
    munit_assert_not_null(strstr(s, "(ref.i31 (i32.const 1))"));
    munit_assert_not_null(strstr(s, "(ref.i31 (i32.const 2))"));
    munit_assert_not_null(strstr(s, "(call $lua_add)"));

    wat_free(&w);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_string_in_data_segment(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(\"hello\")");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);

    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, "test", 0, 1, 0, &w, err, sizeof(err));
    munit_assert_true(ok);
    const char *s = wat_cstr(&w);
    /* The built-in literal prefix still heads $str_data. */
    munit_assert_not_null(strstr(s, "niltruefalse<float>numberstringtablefunctionboolean"));
    /* A short literal is hoisted into an immutable global with inline bytes and
     * a precomputed FNV-1a hash, not placed in $str_data. */
    munit_assert_null(strstr(s, "hello\""));
    munit_assert_not_null(strstr(s, "(array.new_fixed $LuaArr 5 (i32.const 104) (i32.const 101) "
                                    "(i32.const 108) (i32.const 108) (i32.const 111)) "
                                    "(i32.const 1335831723)"));
    wat_free(&w);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* A string literal that occurs several times in the program is declared as
 * one hoisted global. Here `zqxw` is referenced three times (two stores + one
 * load): exactly one `(global $kstr_…)` declaration carries its bytes, and
 * every access site reads that global (so the key is the same object at each
 * site — table lookups then hit on identity). */
static MunitResult test_data_segment_dedups(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("local t = {} t.zqxw = 1 t.zqxw = 2 print(t.zqxw)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);

    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, "test", 0, 1, 0, &w, err, sizeof(err));
    if (!ok) munit_logf(MUNIT_LOG_ERROR, "codegen: %s", err);
    munit_assert_true(ok);
    const char *s = wat_cstr(&w);
    munit_assert_null(strstr(s, "zqxw"));
    const char *bytes = "(array.new_fixed $LuaArr 4 (i32.const 122) (i32.const 113) "
                        "(i32.const 120) (i32.const 119))";
    int count = 0;
    for (const char *p = strstr(s, bytes); p; p = strstr(p + 1, bytes)) count++;
    munit_assert_int(count, ==, 1);
    /* Recover the global's name from its declaration and count its readers. */
    const char *gname = strstr(s, bytes);
    while (gname > s && strncmp(gname, "(global $kstr_", 14) != 0) gname--;
    char name[64];
    sscanf(gname + 8, "%63s", name);
    char ref[80];
    snprintf(ref, sizeof ref, "(global.get %s)", name);
    int refs = 0;
    for (const char *p = strstr(s, ref); p; p = strstr(p + 1, ref)) refs++;
    munit_assert_int(refs, ==, 3);

    wat_free(&w);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_user_function_emitted(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("local function f(x) return x end print(f(7))");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);

    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, "test", 0, 1, 0, &w, err, sizeof(err));
    if (!ok) munit_logf(MUNIT_LOG_ERROR, "codegen: %s", err);
    munit_assert_true(ok);
    const char *s = wat_cstr(&w);
    munit_assert_not_null(strstr(s, "(func $user_0"));
    munit_assert_not_null(strstr(s, "(elem declare func $user_0)"));
    munit_assert_not_null(strstr(s, "(ref.func $user_0)"));
    wat_free(&w);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_pool_pointer_stability(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    /* NodePool must hand out pointers that stay valid as more allocations are
     * made. Earlier implementations grew via realloc, which silently
     * invalidated previously-returned pointers when the kernel had to relocate
     * the buffer. The bug went unnoticed on x86_64 (glibc realloc rarely
     * moves small blocks) but surfaced as out-of-memory + segfault when the
     * compiler ran inside Emscripten's smaller heap. */
    NodePool pool; node_pool_init(&pool);
    int *ptrs[2048];
    for (int i = 0; i < 2048; i++) {
        ptrs[i] = node_pool_alloc(&pool, sizeof(int));
        *ptrs[i] = i ^ 0x5a5a5a5a;
    }
    /* Allocate a lot more (well past the original 4 KB pool size) — guaranteed
     * to grow the pool and, if it ever moves, invalidate ptrs[*]. */
    for (int i = 0; i < 4096; i++) (void)node_pool_alloc(&pool, 64);
    for (int i = 0; i < 2048; i++) {
        munit_assert_int(*ptrs[i], ==, (i ^ 0x5a5a5a5a));
    }
    node_pool_free(&pool);
    return MUNIT_OK;
}

/* Compile `src` at the default optimization level and return a malloc'd copy
 * of the `$main` function's text and of the functions its loops were outlined
 * into (prelude and user functions excluded), so a test can assert what the
 * main chunk lowers to. */
static char *main_func_wat(const char *src) {
    TokenList t = lex(src);
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);
    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, "test", 0, 1, 0, &w, err, sizeof(err));
    if (!ok) munit_logf(MUNIT_LOG_ERROR, "codegen: %s", err);
    munit_assert_true(ok);
    const char *s = wat_cstr(&w);
    const char *start = strstr(s, "(func $main (export \"main\")");
    munit_assert_not_null(start);
    const char *end = strstr(start, "\n  )");
    munit_assert_not_null(end);
    /* The main chunk's code includes the functions its loops were outlined
     * into ($ol_N, right after $main). */
    static const char OL[] = "\n  )\n  (func $ol_";
    while (strncmp(end, OL, sizeof OL - 1) == 0) end = strstr(end + 4, "\n  )");
    size_t n = (size_t)(end - start);
    char *out = malloc(n + 1);
    memcpy(out, start, n);
    out[n] = '\0';
    wat_free(&w);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return out;
}

/* A float compared with an integer literal (or a float-typed value with an
 * int-typed one) is lowered to an unboxed compare: no generic $lua_lt/$lua_gt
 * and no box_num of the operands. Lua compares int vs float exactly, so this
 * is an f64 compare only when the literal is exactly representable. */
static MunitResult test_mixed_compare_unboxed(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    /* typed float local vs int literal / int-typed local */
    char *m = main_func_wat("local x = 0.5\n"
                            "for _ = 1, 3 do x = x * 1.5 end\n"
                            "local n = 2\n"
                            "if x > 1 then print(1) end\n"
                            "if 0 <= x then print(2) end\n"
                            "if x < n then print(3) end\n"
                            "print(x == 1, x ~= n)\n");
    munit_assert_null(strstr(m, "$lua_lt"));
    munit_assert_null(strstr(m, "$lua_gt"));
    munit_assert_null(strstr(m, "$lua_le"));
    munit_assert_null(strstr(m, "$lua_ge"));
    munit_assert_null(strstr(m, "$lua_eq"));
    munit_assert_null(strstr(m, "$lua_neq"));
    free(m);
    /* maybe-typed local (from a table read) vs int literal: a float cell takes
     * an inline f64 compare against the literal (the generic helper remains
     * only for non-numeric cells) */
    m = main_func_wat("local t = {1.5}\n"
                      "local y = t[1] * 2\n"
                      "if y > 600 then print(1) end\n"
                      "if y < 0 then print(2) end\n"
                      "if y == 9007199254740993 then print(3) end\n");
    munit_assert_not_null(strstr(m, "(f64.convert_i64_s (i64.const 600)))"));
    munit_assert_not_null(strstr(m, "(f64.convert_i64_s (i64.const 0)))"));
    /* beyond 2^53 the exact helper is used instead */
    munit_assert_not_null(strstr(m, "(call $float_eq_int"));
    free(m);
    return MUNIT_OK;
}

/* A local used only as a table key (`local id = alive[i]; life[id]`) is
 * maybe-typed, so the reads and writes through it take the unboxed-key entry
 * points instead of the generic $lua_index / $lua_tabset. */
static MunitResult test_key_local_maybe_typed(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    char *m = main_func_wat("local alive, life = {1, 2}, {0.5, 1.5}\n"
                            "for i = 1, #alive do\n"
                            "  local id = alive[i]\n"
                            "  life[id] = life[id] - 0.25\n"
                            "end\n");
    munit_assert_null(strstr(m, "(call $lua_index\n"));
    munit_assert_null(strstr(m, "(call $lua_tabset\n"));
    munit_assert_not_null(strstr(m, "$lua_index_mk"));
    free(m);
    /* ...including through a multi-target store into captured tables, which
     * goes through lowering temporaries (no $ArgArr staging, no generic set) */
    m = main_func_wat("local px, py = {0.5}, {1.5}\n"
                      "local function f() return px, py end\n"
                      "local ids = {1}\n"
                      "for i = 1, #ids do\n"
                      "  local id = ids[i]\n"
                      "  local x = px[id] * 2\n"
                      "  px[id], py[id] = x, x + py[id]\n"
                      "end\n");
    munit_assert_null(strstr(m, "(local.set $tmp_lhs_t"));
    munit_assert_null(strstr(m, "(call $lua_tabset\n"));
    munit_assert_not_null(strstr(m, "$lua_tabset_ik_f"));
    free(m);
    return MUNIT_OK;
}

/* A single-value call whose callee is only known at run time (a method, a
 * function read from a table, a parameter) goes through the closure's fast
 * entry: arguments in registers, one result, no $ArgArr built either side. */
static MunitResult test_dynamic_call_fast(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    char *m = main_func_wat("local O = {}\n"
                            "function O.get(self, k) return self[k] end\n"
                            "local o = {x = 1, get = O.get}\n"
                            "local v = o:get(\"x\")\n"
                            "local w = O.get(o, \"x\")\n"
                            "o:get(\"x\")\n"
                            "print(v, w)\n");
    munit_assert_not_null(strstr(m, "$lua_call1"));
    munit_assert_null(strstr(m, "array.new_fixed $ArgArr"));
    munit_assert_null(strstr(m, "$args_first"));
    free(m);
    return MUNIT_OK;
}

/* A constructor whose field names are distinct constants starts from its
 * site's cached shape and fills values by position; computed or duplicate
 * names keep the incremental path. */
static MunitResult test_ctor_shape(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    char *m = main_func_wat("local a = {x = 1, y = 2.5, 10}\n"
                            "print(a)\n");
    munit_assert_not_null(strstr(m, "$tab_new_shaped"));
    munit_assert_not_null(strstr(m, "$tab_put_pos_f"));
    munit_assert_null(strstr(m, "$tab_set_hash_str"));
    free(m);
    m = main_func_wat("local k = 'x'\n"
                      "local a = {[k] = 1, y = 2}\n"
                      "local b = {x = 1, x = 2}\n"
                      "print(a, b)\n");
    munit_assert_null(strstr(m, "$tab_new_shaped"));
    free(m);
    return MUNIT_OK;
}

/* Constant-key reads/writes and method lookups go through per-site inline
 * caches ($ic_N / $mic_N) at the default optimization level. */
static MunitResult test_inline_caches(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    char *m = main_func_wat("local o = {x = 1}\n"
                            "o.x = o.x + 1\n"
                            "o.y = 'a'\n"
                            "print(o:get())\n");
    munit_assert_not_null(strstr(m, "$lua_index_ic"));
    munit_assert_not_null(strstr(m, "$lua_tabset_ic"));
    munit_assert_not_null(strstr(m, "$lua_method_ic"));
    munit_assert_null(strstr(m, "$lua_index_sk"));
    munit_assert_null(strstr(m, "$lua_tabset_sk"));
    free(m);
    return MUNIT_OK;
}

/* type() returns preallocated name strings, and a literal type name in the
 * program is that same object, so `type(x) == "number"` needs no allocation
 * and compares by identity. */
static MunitResult test_type_names_shared(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    char *m = main_func_wat("local x = 1\n"
                            "print(type(x) == \"number\", type(x) == \"table\")\n");
    munit_assert_not_null(strstr(m, "$g_tname_number"));
    munit_assert_not_null(strstr(m, "$g_tname_table"));
    free(m);
    return MUNIT_OK;
}

/* A right-nested `..` chain is built by one n-ary concatenation; a
 * parenthesized left operand keeps its own pairwise concatenation. */
static MunitResult test_concat_flatten(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    char *m = main_func_wat("local a, b = 'x', 'y'\n"
                            "print(a .. b .. a .. b)\n");
    munit_assert_not_null(strstr(m, "$lua_concat4"));
    free(m);
    m = main_func_wat("local a, b = 'x', 'y'\n"
                      "print((a .. b) .. a)\n");
    munit_assert_null(strstr(m, "$lua_concat3"));
    free(m);
    return MUNIT_OK;
}

/* Compile `src` at optimization level `opt`; a malloc'd copy of the module's
 * whole WAT. */
static char *module_wat(const char *src, int opt) {
    TokenList t = lex(src);
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);
    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, "test", 0, opt, 0, &w, err, sizeof(err));
    if (!ok) munit_logf(MUNIT_LOG_ERROR, "codegen: %s", err);
    munit_assert_true(ok);
    char *out = strdup(wat_cstr(&w));
    wat_free(&w);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return out;
}

static int count_of(const char *s, const char *needle) {
    int n = 0;
    for (const char *p = strstr(s, needle); p; p = strstr(p + 1, needle)) n++;
    return n;
}

/* The main chunk's outermost loops, and those of a local function it calls
 * exactly once outside any loop, run in functions of their own ($ol_N) that
 * the caller calls until they report the loop done (src/codegen/outline.c). */
static MunitResult test_run_once_loops(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    const char *loop = "local s = 0\nfor i = 1, 10 do s = s + i end\nprint(s)\n";
    char *m = module_wat(loop, 1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 1);
    /* only the first call runs the loop's setup; the header suspends */
    munit_assert_not_null(strstr(m, "(if (i32.eqz (local.get $olp_resume)) (then"));
    munit_assert_not_null(strstr(m, "(br_if $ol_suspend (i32.lt_s (local.get $ol_budget) (i32.const 0)))"));
    munit_assert_not_null(strstr(m, "(call $ol_0 (local.get $olc_st)"));
    free(m);
    /* -O0 and a zero budget keep loops inline */
    m = module_wat(loop, 0);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 0);
    free(m);
    int saved = codegen_loop_chunk;
    codegen_loop_chunk = 0;
    m = module_wat(loop, 1);
    codegen_loop_chunk = saved;
    munit_assert_int(count_of(m, "(func $ol_"), ==, 0);
    free(m);
    /* a goto out of a loop keeps it inline; an inner numeric for goes with its
     * outer one (counting the budget down) and, past a trip-count check, can
     * also continue in a function of its own, resumed after its setup */
    m = module_wat("for i = 1, 3 do if i == 2 then goto out end end\n::out::\n"
                   "local n = 0\nfor i = 1, 2 do for j = 1, 2 do n = n + j end end\nprint(n)\n",
                   1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 2);
    munit_assert_int(count_of(m, "(br_if $ol_suspend"), ==, 2);
    munit_assert_int(count_of(m, "(local.set $ol_budget (i32.sub"), ==, 3);
    munit_assert_not_null(strstr(m, "(local.set $olc_st (i32.const 1))"));
    free(m);
    /* only under an outlined for with few, constant iterations */
    m = module_wat("local n = 0\nfor i = 1, 1000 do for j = 1, 2 do n = n + j end end\nprint(n)\n", 1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 1);
    free(m);
    m = module_wat("local n, m = 0, 3\nfor i = 1, m do for j = 1, 2 do n = n + j end end\nprint(n)\n", 1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 1);
    free(m);
    /* deeper loops are not split again */
    m = module_wat("local n = 0\nfor i = 1, 2 do for j = 1, 2 do for k = 1, 2 do n = n + k end end end\nprint(n)\n", 1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 2);
    free(m);
    /* a function handed to pcall, and a global function defined and called
     * once, run once too */
    m = module_wat("pcall(function() local s = 0 for i = 1, 10 do s = s + i end print(s) end)\n", 1);
    munit_assert_int(count_of(m, "(func $ol_"), >, 0);
    free(m);
    m = module_wat("function main() local s = 0 for i = 1, 10 do s = s + i end print(s) end\nmain()\n", 1);
    munit_assert_int(count_of(m, "(func $ol_"), >, 0);
    free(m);
    /* ... but not a global something can reach by name, or one called twice */
    m = module_wat("function main() local s = 0 for i = 1, 10 do s = s + i end print(s) end\nmain()\n"
                   "local g = _G\n",
                   1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 0);
    free(m);
    m = module_wat("function main() local s = 0 for i = 1, 10 do s = s + i end print(s) end\nmain() main()\n", 1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 0);
    free(m);
    /* a local function called once: its loop is outlined (in each of its
     * entries), reaching upvalues through the closure, and a return inside it
     * comes back through the caller */
    m = module_wat("local k = 2\n"
                   "local function f(n) for i = 1, n do if i * k > n then return i end end return 0 end\n"
                   "print(f(50))\n",
                   1);
    munit_assert_int(count_of(m, "(func $ol_"), >, 0);
    munit_assert_not_null(strstr(m, "(param $closure (ref $LuaClosure))"));
    munit_assert_not_null(strstr(m, "(local.set $ol_status (i32.const 3))"));
    free(m);
    /* ... but not when it is called twice, or from a loop */
    m = module_wat("local function f(n) local s = 0 for i = 1, n do s = s + i end return s end\n"
                   "print(f(10), f(20))\n",
                   1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 0);
    free(m);
    m = module_wat("local function f(n) local s = 0 for i = 1, n do s = s + i end return s end\n"
                   "local t = 0\nwhile t < 1 do t = t + f(3) end\nprint(t)\n",
                   1);
    munit_assert_int(count_of(m, "(func $ol_"), ==, 1); /* the main chunk's own loop */
    free(m);
    return MUNIT_OK;
}

static MunitTest tests[] = {
    { "/emits_expected",       test_emits_expected,         NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/boxed_fallback_o0",    test_emits_boxed_fallback_o0, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/string_data",          test_string_in_data_segment, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/data_segment_dedups",  test_data_segment_dedups,    NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/user_function",        test_user_function_emitted,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/pool_pointer_stability", test_pool_pointer_stability, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/mixed_compare_unboxed", test_mixed_compare_unboxed, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/key_local_maybe_typed", test_key_local_maybe_typed, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/dynamic_call_fast",    test_dynamic_call_fast,      NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/ctor_shape",           test_ctor_shape,             NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/inline_caches",        test_inline_caches,          NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/type_names_shared",    test_type_names_shared,      NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/concat_flatten",       test_concat_flatten,         NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/run_once_loops",       test_run_once_loops,         NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/codegen", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) { return munit_suite_main(&suite, NULL, argc, argv); }
