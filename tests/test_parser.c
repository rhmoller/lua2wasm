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

    Stmt *st = r.program.items[0];
    munit_assert_int(st->kind, ==, STMT_EXPR);
    Expr *call = st->as.expr_stmt.expr;
    munit_assert_int(call->kind, ==, EXPR_CALL);
    munit_assert_size(call->as.call.nargs, ==, 1);

    Expr *arg = call->as.call.args[0];
    munit_assert_int(arg->kind, ==, EXPR_BINOP);
    munit_assert_int(arg->as.binop.op, ==, BIN_ADD);
    munit_assert_int(arg->as.binop.lhs->kind, ==, EXPR_INT);
    munit_assert_int64(arg->as.binop.lhs->as.i_val, ==, 1);
    munit_assert_int(arg->as.binop.rhs->kind, ==, EXPR_INT);
    munit_assert_int64(arg->as.binop.rhs->as.i_val, ==, 2);

    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_precedence(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(1+2*3)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);
    Expr *call = r.program.items[0]->as.expr_stmt.expr;
    Expr *arg = call->as.call.args[0];
    munit_assert_int(arg->as.binop.op, ==, BIN_ADD);
    munit_assert_int(arg->as.binop.rhs->kind, ==, EXPR_BINOP);
    munit_assert_int(arg->as.binop.rhs->as.binop.op, ==, BIN_MUL);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_local_and_assign(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("local x = 1 x = x + 2 print(x)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);
    munit_assert_size(r.program.count, ==, 3);
    munit_assert_int(r.program.items[0]->kind, ==, STMT_LOCAL);
    munit_assert_int(r.program.items[1]->kind, ==, STMT_ASSIGN);
    munit_assert_int(r.program.items[1]->as.assign.local_idx, ==,
                     r.program.items[0]->as.local.local_idx);
    munit_assert_int(r.program.items[2]->kind, ==, STMT_EXPR);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_if_while(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex(
        "local i = 0 "
        "while i < 3 do "
        "  if i == 1 then print(i) else print(0) end "
        "  i = i + 1 "
        "end");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    if (!r.ok) munit_logf(MUNIT_LOG_ERROR, "parse: %s", r.error);
    munit_assert_true(r.ok);
    munit_assert_int(r.program.items[1]->kind, ==, STMT_WHILE);
    Stmt *w = r.program.items[1];
    munit_assert_size(w->as.while_stmt.body.count, ==, 2);
    munit_assert_int(w->as.while_stmt.body.items[0]->kind, ==, STMT_IF);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitTest tests[] = {
    { "/print_sum_shape",  test_print_sum_shape,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/precedence",       test_precedence,       NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/local_and_assign", test_local_and_assign, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/if_while",         test_if_while,         NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/parser", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) { return munit_suite_main(&suite, NULL, argc, argv); }
