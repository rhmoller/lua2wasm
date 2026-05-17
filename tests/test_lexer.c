#include "../src/lexer.h"
#include "../third_party/munit/munit.h"
#include <string.h>

static MunitResult test_print_sum(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(1+2)");
    munit_assert_size(t.count, ==, 7); /* IDENT ( NUM + NUM ) EOF */
    munit_assert_int(t.items[0].kind, ==, TOK_IDENT);
    munit_assert_size(t.items[0].len, ==, 5);
    munit_assert_int(t.items[1].kind, ==, TOK_LPAREN);
    munit_assert_int(t.items[2].kind, ==, TOK_NUMBER);
    munit_assert_int64(t.items[2].number, ==, 1);
    munit_assert_int(t.items[3].kind, ==, TOK_PLUS);
    munit_assert_int(t.items[4].kind, ==, TOK_NUMBER);
    munit_assert_int64(t.items[4].number, ==, 2);
    munit_assert_int(t.items[5].kind, ==, TOK_RPAREN);
    munit_assert_int(t.items[6].kind, ==, TOK_EOF);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_skips_comment(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("-- hi\n42");
    munit_assert_size(t.count, ==, 2);
    munit_assert_int(t.items[0].kind, ==, TOK_NUMBER);
    munit_assert_int64(t.items[0].number, ==, 42);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitTest tests[] = {
    { "/print_sum",     test_print_sum,     NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/skips_comment", test_skips_comment, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/lexer", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) {
    return munit_suite_main(&suite, NULL, argc, argv);
}
