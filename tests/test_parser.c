#include "../src/lexer.h"
#include "../src/parser.h"
#include "../third_party/munit/munit.h"

static MunitResult test_print_sum_shape(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("print(1+2)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);
    munit_assert_size(r.main_body.count, ==, 1);

    Stmt *st = r.main_body.items[0];
    munit_assert_int(st->kind, ==, STMT_EXPR);
    Expr *call = st->as.expr_stmt.expr;
    munit_assert_int(call->kind, ==, EXPR_CALL);
    munit_assert_size(call->as.call.nargs, ==, 1);

    Expr *arg = call->as.call.args[0];
    munit_assert_int(arg->kind, ==, EXPR_BINOP);
    munit_assert_int(arg->as.binop.op, ==, BIN_ADD);
    munit_assert_int(arg->as.binop.lhs->kind, ==, EXPR_INT);
    munit_assert_int64(arg->as.binop.lhs->as.i_val, ==, 1);

    parse_result_free(&r);
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
    Expr *call = r.main_body.items[0]->as.expr_stmt.expr;
    Expr *arg = call->as.call.args[0];
    munit_assert_int(arg->as.binop.op, ==, BIN_ADD);
    munit_assert_int(arg->as.binop.rhs->kind, ==, EXPR_BINOP);
    munit_assert_int(arg->as.binop.rhs->as.binop.op, ==, BIN_MUL);
    parse_result_free(&r);
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
    munit_assert_size(r.main_body.count, ==, 3);
    munit_assert_int(r.main_body.items[0]->kind, ==, STMT_LOCAL);
    munit_assert_int(r.main_body.items[1]->kind, ==, STMT_ASSIGN);
    munit_assert_int(r.main_body.items[1]->as.assign.n_targets, ==, 1);
    munit_assert_int(r.main_body.items[1]->as.assign.targets[0].kind, ==, TGT_VAR);
    munit_assert_int(r.main_body.items[1]->as.assign.targets[0].as.var.idx, ==,
                     r.main_body.items[0]->as.local.local_idxs[0]);
    munit_assert_int(r.main_body.items[1]->as.assign.targets[0].as.var.kind, ==, VAR_LOCAL);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_local_function(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex(
        "local function f(x) return x + 1 end "
        "print(f(2))");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    if (!r.ok) munit_logf(MUNIT_LOG_ERROR, "parse: %s", r.error);
    munit_assert_true(r.ok);
    munit_assert_size(r.funcs.count, ==, 1);
    LuaFunc *f = r.funcs.items[0];
    munit_assert_int(f->n_params, ==, 1);
    munit_assert_int(f->n_upvalues, ==, 0);
    munit_assert_int(r.main_body.items[0]->kind, ==, STMT_LOCAL_FUNC);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitResult test_closure_captures(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex(
        "local function counter() "
        "  local n = 0 "
        "  local function tick() n = n + 1 return n end "
        "  return tick "
        "end");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    if (!r.ok) munit_logf(MUNIT_LOG_ERROR, "parse: %s", r.error);
    munit_assert_true(r.ok);
    munit_assert_size(r.funcs.count, ==, 2);
    /* Inner function `tick` captures `n` from counter. */
    LuaFunc *tick = r.funcs.items[1];
    munit_assert_int(tick->n_upvalues, ==, 1);
    munit_assert_int(tick->upvalues[0].src, ==, UPVAL_FROM_LOCAL);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

static MunitTest tests[] = {
    { "/print_sum_shape",   test_print_sum_shape,   NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/precedence",        test_precedence,        NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/local_and_assign",  test_local_and_assign,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/local_function",    test_local_function,    NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/closure_captures",  test_closure_captures,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/parser", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) { return munit_suite_main(&suite, NULL, argc, argv); }
