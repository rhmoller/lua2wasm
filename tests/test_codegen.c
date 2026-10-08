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
 * of the `$main` function's text (prelude and user functions excluded), so a
 * test can assert what the main chunk lowers to. */
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

static MunitTest tests[] = {
    { "/emits_expected",       test_emits_expected,         NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/boxed_fallback_o0",    test_emits_boxed_fallback_o0, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/string_data",          test_string_in_data_segment, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/data_segment_dedups",  test_data_segment_dedups,    NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/user_function",        test_user_function_emitted,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/pool_pointer_stability", test_pool_pointer_stability, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/mixed_compare_unboxed", test_mixed_compare_unboxed, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/codegen", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) { return munit_suite_main(&suite, NULL, argc, argv); }
