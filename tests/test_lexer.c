#include "../src/lexer.h"
#include "../third_party/munit/munit.h"
#include <string.h>

static MunitResult test_print_sum(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(1+2)");
    munit_assert_true(t.ok);
    munit_assert_size(t.count, ==, 7); /* IDENT ( INT + INT ) EOF */
    munit_assert_int(t.items[0].kind, ==, TOK_IDENT);
    munit_assert_int(t.items[2].kind, ==, TOK_INT);
    munit_assert_int64(t.items[2].i_val, ==, 1);
    munit_assert_int(t.items[3].kind, ==, TOK_PLUS);
    munit_assert_int(t.items[4].kind, ==, TOK_INT);
    munit_assert_int64(t.items[4].i_val, ==, 2);
    munit_assert_int(t.items[5].kind, ==, TOK_RPAREN);
    munit_assert_int(t.items[6].kind, ==, TOK_EOF);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_keywords_and_ops(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("local x = 1 if x <= 2 then end while true do end");
    munit_assert_true(t.ok);
    /* spot-check a few */
    munit_assert_int(t.items[0].kind, ==, TOK_KW_LOCAL);
    munit_assert_int(t.items[1].kind, ==, TOK_IDENT);
    munit_assert_int(t.items[2].kind, ==, TOK_ASSIGN);
    munit_assert_int(t.items[4].kind, ==, TOK_KW_IF);
    munit_assert_int(t.items[6].kind, ==, TOK_LE);
    munit_assert_int(t.items[8].kind, ==, TOK_KW_THEN);
    munit_assert_int(t.items[9].kind, ==, TOK_KW_END);
    munit_assert_int(t.items[10].kind, ==, TOK_KW_WHILE);
    munit_assert_int(t.items[11].kind, ==, TOK_KW_TRUE);
    munit_assert_int(t.items[12].kind, ==, TOK_KW_DO);
    munit_assert_int(t.items[13].kind, ==, TOK_KW_END);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_string_literal(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("\"hi\\n\" 'world'");
    munit_assert_true(t.ok);
    munit_assert_int(t.items[0].kind, ==, TOK_STRING);
    munit_assert_size(t.items[0].str_len, ==, 3);
    munit_assert_memory_equal(3, t.items[0].str_buf, "hi\n");
    munit_assert_int(t.items[1].kind, ==, TOK_STRING);
    munit_assert_memory_equal(5, t.items[1].str_buf, "world");
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_float_literal(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("1.5 .25 2e3");
    munit_assert_true(t.ok);
    munit_assert_int(t.items[0].kind, ==, TOK_FLOAT);
    munit_assert_double(t.items[0].f_val, ==, 1.5);
    munit_assert_int(t.items[1].kind, ==, TOK_FLOAT);
    munit_assert_double(t.items[1].f_val, ==, 0.25);
    munit_assert_int(t.items[2].kind, ==, TOK_FLOAT);
    munit_assert_double(t.items[2].f_val, ==, 2000.0);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_long_comment(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("1 --[[ comment\nspanning lines ]] 2");
    munit_assert_true(t.ok);
    munit_assert_size(t.count, ==, 3); /* INT INT EOF */
    munit_assert_int64(t.items[0].i_val, ==, 1);
    munit_assert_int64(t.items[1].i_val, ==, 2);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_unterminated_string(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("local s = \"oops");
    munit_assert_false(t.ok);
    munit_assert_not_null(strstr(t.err, "unterminated string"));
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_unknown_escape_reports_char(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("local s = \"a\\q\"");
    munit_assert_false(t.ok);
    /* Diagnostic must name the offending escape so users can find it. */
    munit_assert_not_null(strstr(t.err, "\\q"));
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_hex_escape(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("\"\\x41\\x7a\"");
    munit_assert_true(t.ok);
    munit_assert_int(t.items[0].kind, ==, TOK_STRING);
    munit_assert_size(t.items[0].str_len, ==, 2);
    munit_assert_memory_equal(2, t.items[0].str_buf, "Az");
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_decimal_escape(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("\"\\65\\90\\255\"");
    munit_assert_true(t.ok);
    munit_assert_int(t.items[0].kind, ==, TOK_STRING);
    munit_assert_size(t.items[0].str_len, ==, 3);
    munit_assert_uint8(((unsigned char *)t.items[0].str_buf)[0], ==, 65);
    munit_assert_uint8(((unsigned char *)t.items[0].str_buf)[1], ==, 90);
    munit_assert_uint8(((unsigned char *)t.items[0].str_buf)[2], ==, 255);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_decimal_escape_out_of_range(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("\"\\256\"");
    munit_assert_false(t.ok);
    munit_assert_not_null(strstr(t.err, "out of range"));
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_unicode_escape(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    /* U+00E9 (é)  -> 2 bytes: c3 a9. U+20AC (€) -> 3 bytes: e2 82 ac. */
    TokenList t = lex("\"\\u{e9}\\u{20ac}\"");
    munit_assert_true(t.ok);
    munit_assert_size(t.items[0].str_len, ==, 5);
    munit_assert_memory_equal(5, t.items[0].str_buf, "\xc3\xa9\xe2\x82\xac");
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_z_escape_skips_whitespace(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    /* `\z` swallows ALL subsequent whitespace in the source, including the
     * real newline that would otherwise be illegal inside a short string. */
    TokenList t = lex("\"a\\z   \n\t  b\"");
    munit_assert_true(t.ok);
    munit_assert_size(t.items[0].str_len, ==, 2);
    munit_assert_memory_equal(2, t.items[0].str_buf, "ab");
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitTest tests[] = {
    { "/print_sum",     test_print_sum,        NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/keywords_ops",  test_keywords_and_ops, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/string",        test_string_literal,   NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/float",         test_float_literal,    NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/long_comment",  test_long_comment,     NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/unterminated_string",      test_unterminated_string,        NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/unknown_escape_named",     test_unknown_escape_reports_char,NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/escape_hex",               test_hex_escape,                 NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/escape_decimal",           test_decimal_escape,             NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/escape_decimal_oor",       test_decimal_escape_out_of_range,NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/escape_unicode",           test_unicode_escape,             NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/escape_z_skips_ws",        test_z_escape_skips_whitespace,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/lexer", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) {
    return munit_suite_main(&suite, NULL, argc, argv);
}
