#include "../src/lexer.h"
#include "../src/parser.h"
#include "../third_party/munit/munit.h"

static MunitResult test_print_sum_shape(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(1+2)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);
    munit_assert_size(r.program.count, ==, 1);

    LuaNode *call = r.program.items[0];
    munit_assert_int(call->kind, ==, NODE_CALL);
    munit_assert_int(call->as.call.callee->kind, ==, NODE_IDENT);
    munit_assert_size(call->as.call.nargs, ==, 1);

    LuaNode *arg = call->as.call.args[0];
    munit_assert_int(arg->kind, ==, NODE_BINOP);
    munit_assert_int(arg->as.binop.op, ==, BINOP_ADD);
    munit_assert_int(arg->as.binop.lhs->kind, ==, NODE_NUMBER);
    munit_assert_int64(arg->as.binop.lhs->as.number.value, ==, 1);
    munit_assert_int(arg->as.binop.rhs->kind, ==, NODE_NUMBER);
    munit_assert_int64(arg->as.binop.rhs->as.number.value, ==, 2);

    program_free(&r.program);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_precedence(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    /* 1 + 2 * 3 should parse as 1 + (2 * 3) */
    TokenList t = lex("1+2*3");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);
    LuaNode *root = r.program.items[0];
    munit_assert_int(root->kind, ==, NODE_BINOP);
    munit_assert_int(root->as.binop.op, ==, BINOP_ADD);
    munit_assert_int(root->as.binop.rhs->kind, ==, NODE_BINOP);
    munit_assert_int(root->as.binop.rhs->as.binop.op, ==, BINOP_MUL);
    program_free(&r.program);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitTest tests[] = {
    { "/print_sum_shape", test_print_sum_shape, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/precedence",      test_precedence,      NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/parser", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) { return munit_suite_main(&suite, NULL, argc, argv); }
