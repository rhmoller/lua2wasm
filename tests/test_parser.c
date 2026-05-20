#include "../src/lexer.h"
#include "../src/parser.h"
#include "../third_party/munit/munit.h"
#include <string.h>

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

static MunitResult test_vararg_outside_vararg_rejected(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    /* Inner function f has no `...`, so referencing `...` must error. */
    TokenList t = lex("local function f() return ... end");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_false(r.ok);
    munit_assert_not_null(strstr(r.error, "..."));
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* Two-frame upvalue chain: inner captures `x` from grandparent via an
 * intermediate parent. The middle frame must register an UPVAL_FROM_UPVAL
 * and the original local must be flagged captured (so codegen boxes it). */
static MunitResult test_upvalue_two_frames(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex(
        "local function outer() "
        "  local x = 1 "
        "  local function mid() "
        "    local function inner() return x end "
        "    return inner "
        "  end "
        "  return mid "
        "end");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    if (!r.ok) munit_logf(MUNIT_LOG_ERROR, "parse: %s", r.error);
    munit_assert_true(r.ok);
    munit_assert_size(r.funcs.count, ==, 3);
    LuaFunc *outer = r.funcs.items[0];
    LuaFunc *mid   = r.funcs.items[1];
    LuaFunc *inner = r.funcs.items[2];
    /* outer's local `x` (slot 0) must be flagged captured. */
    munit_assert_not_null(outer->captured);
    munit_assert_uint8(outer->captured[0], ==, 1);
    /* mid takes UPVAL_FROM_LOCAL referring to outer's slot 0. */
    munit_assert_int(mid->n_upvalues, ==, 1);
    munit_assert_int(mid->upvalues[0].src, ==, UPVAL_FROM_LOCAL);
    munit_assert_int(mid->upvalues[0].idx, ==, 0);
    /* inner takes UPVAL_FROM_UPVAL referring to mid's upval 0. */
    munit_assert_int(inner->n_upvalues, ==, 1);
    munit_assert_int(inner->upvalues[0].src, ==, UPVAL_FROM_UPVAL);
    munit_assert_int(inner->upvalues[0].idx, ==, 0);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* Multi-target assign: `a, b = 1, 2` must parse as one STMT_ASSIGN with
 * two targets and two values, both targeting locals in slot order. */
static MunitResult test_multi_target_assign(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("local a, b = 0, 0; a, b = 10, 20");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    if (!r.ok) munit_logf(MUNIT_LOG_ERROR, "parse: %s", r.error);
    munit_assert_true(r.ok);
    munit_assert_size(r.main_body.count, ==, 2);
    Stmt *as = r.main_body.items[1];
    munit_assert_int(as->kind, ==, STMT_ASSIGN);
    munit_assert_int(as->as.assign.n_targets, ==, 2);
    munit_assert_int(as->as.assign.n_values, ==, 2);
    munit_assert_int(as->as.assign.targets[0].kind, ==, TGT_VAR);
    munit_assert_int(as->as.assign.targets[1].kind, ==, TGT_VAR);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* Dotted function definition: `function t.k() end` lowers to
 * STMT_ASSIGN with one TGT_INDEX target whose key is the string "k". */
static MunitResult test_dotted_function_def(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("global t = {} function t.greet() end");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    if (!r.ok) munit_logf(MUNIT_LOG_ERROR, "parse: %s", r.error);
    munit_assert_true(r.ok);
    /* find the assign statement */
    Stmt *as = NULL;
    for (size_t i = 0; i < r.main_body.count; i++)
        if (r.main_body.items[i]->kind == STMT_ASSIGN) { as = r.main_body.items[i]; break; }
    munit_assert_not_null(as);
    munit_assert_int(as->as.assign.n_targets, ==, 1);
    munit_assert_int(as->as.assign.targets[0].kind, ==, TGT_INDEX);
    Expr *key = as->as.assign.targets[0].as.index.key;
    munit_assert_int(key->kind, ==, EXPR_STRING);
    munit_assert_size(key->as.s.len, ==, 5);
    munit_assert_memory_equal(5, key->as.s.bytes, "greet");
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* `function t:greet() ... end` lowers to assignment with an implicit
 * `self` parameter prepended. */
static MunitResult test_method_def_has_self(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("global t = {} function t:greet(a, b) end");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    if (!r.ok) munit_logf(MUNIT_LOG_ERROR, "parse: %s", r.error);
    munit_assert_true(r.ok);
    munit_assert_size(r.funcs.count, ==, 1);
    LuaFunc *fn = r.funcs.items[0];
    munit_assert_int(fn->n_params, ==, 3); /* self, a, b */
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* For-numeric is distinct from for-generic: `for i = 1, 10 do` is
 * STMT_FOR_NUM, `for k, v in pairs(t) do` is STMT_FOR_GEN. */
static MunitResult test_for_numeric_vs_generic(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t1 = lex("for i = 1, 10 do end");
    NodePool p1; node_pool_init(&p1);
    ParseResult r1 = parse(&t1, &p1);
    munit_assert_true(r1.ok);
    munit_assert_int(r1.main_body.items[0]->kind, ==, STMT_FOR_NUM);

    TokenList t2 = lex("local t = {} for k, v in pairs(t) do end");
    NodePool p2; node_pool_init(&p2);
    ParseResult r2 = parse(&t2, &p2);
    munit_assert_true(r2.ok);
    munit_assert_int(r2.main_body.items[1]->kind, ==, STMT_FOR_GEN);
    munit_assert_int(r2.main_body.items[1]->as.for_gen.n_names, ==, 2);

    parse_result_free(&r1); node_pool_free(&p1); tokenlist_free(&t1);
    parse_result_free(&r2); node_pool_free(&p2); tokenlist_free(&t2);
    return MUNIT_OK;
}

/* Bare `x = 42` at top level auto-declares `x` as a global; reading an
 * undeclared name resolves to that global (with nil initialiser). */
static MunitResult test_implicit_global(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex("x = 42 print(x)");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    if (!r.ok) munit_logf(MUNIT_LOG_ERROR, "parse: %s", r.error);
    munit_assert_true(r.ok);
    /* `x` should now appear in the globals table. Built-in pre-declared
     * names (math/string/io/table/_VERSION) come first; `x` is appended. */
    int found = 0;
    for (size_t i = 0; i < r.globals.count; i++) {
        if (r.globals.items[i].name_len == 1 && r.globals.items[i].name[0] == 'x') { found = 1; break; }
    }
    munit_assert_true(found);
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* A function with no captures must have an empty/zero captured bitmap so
 * codegen unboxes its locals. */
static MunitResult test_no_capture_means_unboxed(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    TokenList t = lex(
        "local function f(a, b) "
        "  local c = a + b "
        "  return c "
        "end");
    NodePool pool; node_pool_init(&pool);
    ParseResult r = parse(&t, &pool);
    munit_assert_true(r.ok);
    munit_assert_size(r.funcs.count, ==, 1);
    LuaFunc *fn = r.funcs.items[0];
    munit_assert_int(fn->n_locals, ==, 3); /* a, b, c */
    /* No nested function takes any of these as an upvalue. */
    for (int i = 0; i < fn->n_locals; i++) {
        if (fn->captured) munit_assert_uint8(fn->captured[i], ==, 0);
    }
    parse_result_free(&r);
    node_pool_free(&pool);
    tokenlist_free(&t);
    return MUNIT_OK;
}

/* A malformed parenthesized expression must report a parse error, not
 * crash. Regression: `parse_expr` returns NULL inside `( ... )` and the
 * LPAREN arm dereferenced it (`inner->paren = 1`) -> SIGSEGV. */
static MunitResult test_malformed_paren_no_crash(const MunitParameter params[], void *fixture) {
    (void)params; (void)fixture;
    const char *srcs[] = { "local x = ()", "return (", "local y = (1+)" };
    for (size_t i = 0; i < sizeof(srcs) / sizeof(srcs[0]); i++) {
        TokenList t = lex(srcs[i]);
        NodePool pool; node_pool_init(&pool);
        ParseResult r = parse(&t, &pool);
        munit_assert_false(r.ok);
        parse_result_free(&r);
        node_pool_free(&pool);
        tokenlist_free(&t);
    }
    return MUNIT_OK;
}

static MunitTest tests[] = {
    { "/print_sum_shape",   test_print_sum_shape,   NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/precedence",        test_precedence,        NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/local_and_assign",  test_local_and_assign,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/local_function",    test_local_function,    NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/closure_captures",  test_closure_captures,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/vararg_outside_vararg",   test_vararg_outside_vararg_rejected,  NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/upvalue_two_frames",      test_upvalue_two_frames,              NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/multi_target_assign",     test_multi_target_assign,             NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/dotted_function_def",     test_dotted_function_def,             NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/method_def_has_self",     test_method_def_has_self,             NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/for_num_vs_gen",          test_for_numeric_vs_generic,          NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/implicit_global",         test_implicit_global,                 NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/no_capture_unboxed",      test_no_capture_means_unboxed,        NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { "/malformed_paren_no_crash", test_malformed_paren_no_crash,       NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
    { NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
};

static const MunitSuite suite = {
    "/parser", tests, NULL, 1, MUNIT_SUITE_OPTION_NONE,
};

int main(int argc, char *argv[]) { return munit_suite_main(&suite, NULL, argc, argv); }
