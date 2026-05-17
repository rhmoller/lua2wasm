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
    munit_assert_not_null(strstr(s, "(call $host_print)"));
    munit_assert_not_null(strstr(s, "(func $main (export \"main\")"));
    munit_assert_not_null(strstr(s, "(type $LuaString"));
    munit_assert_not_null(strstr(s, "$str_data"));

    wat_free(&w);
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
    /* Built-in literal prefix is "niltruefalse<float>" (19 bytes); "hello" follows. */
    munit_assert_not_null(strstr(s, "(i32.const 19) (i32.const 5)"));
    munit_assert_not_null(strstr(s, "niltruefalse<float>hello"));
    wat_free(&w);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitTest tests[] = {
    { "/emits_expected", test_emits_expected,         NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/string_data",    test_string_in_data_segment, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/codegen", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) { return munit_suite_main(&suite, NULL, argc, argv); }
