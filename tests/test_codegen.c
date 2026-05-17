#include "../src/codegen.h"
#include "../src/lexer.h"
#include "../src/parser.h"
#include "../src/wat_builder.h"
#include "../third_party/munit/munit.h"
#include <string.h>

static MunitResult test_emits_expected(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(1+2)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);

    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, &w, err, sizeof(err));
    if (!ok) munit_logf(MUNIT_LOG_ERROR, "codegen: %s", err);
    munit_assert_true(ok);

    const char *s = wat_cstr(&w);
    munit_assert_not_null(strstr(s, "(import \"host\" \"print\""));
    munit_assert_not_null(strstr(s, "(ref.i31 (i32.const 1))"));
    munit_assert_not_null(strstr(s, "(ref.i31 (i32.const 2))"));
    munit_assert_not_null(strstr(s, "(call $lua_add)"));
    /* No more direct $host_print call from user code; goes through $lua_call. */
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

static MunitResult test_string_in_data_segment(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(\"hello\")");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);

    WatBuilder w; wat_init(&w);
    char err[256] = {0};
    int ok = codegen_module(&r, &w, err, sizeof(err));
    munit_assert_true(ok);
    const char *s = wat_cstr(&w);
    /* Built-in literal prefix is 51 bytes; "hello" lands somewhere after that. */
    munit_assert_not_null(strstr(s, "niltruefalse<float>numberstringtablefunctionboolean"));
    munit_assert_not_null(strstr(s, "hello"));
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
    int ok = codegen_module(&r, &w, err, sizeof(err));
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

static MunitTest tests[] = {
    { "/emits_expected",       test_emits_expected,         NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/string_data",          test_string_in_data_segment, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/user_function",        test_user_function_emitted,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/pool_pointer_stability", test_pool_pointer_stability, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/codegen", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) { return munit_suite_main(&suite, NULL, argc, argv); }
