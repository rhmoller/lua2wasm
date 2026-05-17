#include "parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================
 * Scope (single chunk; one flat lexical layer of locals, but
 * we track per-block extents so a block's locals fall out of
 * scope at `end`).
 * ============================================================ */

#define MAX_LOCALS 256

typedef struct {
    const char *name;
    size_t name_len;
    int slot;       /* wasm local index */
} LocalSlot;

typedef struct {
    LocalSlot items[MAX_LOCALS];
    int count;
    int next_slot;          /* monotonic - never reused so debug is sane */
} Scope;

static void scope_init(Scope *s) { s->count = 0; s->next_slot = 0; }
static int scope_mark(Scope *s) { return s->count; }
static void scope_rewind(Scope *s, int mark) { s->count = mark; }
static int scope_declare(Scope *s, const char *name, size_t name_len) {
    if (s->count >= MAX_LOCALS) return -1;
    int slot = s->next_slot++;
    s->items[s->count++] = (LocalSlot){ .name = name, .name_len = name_len, .slot = slot };
    return slot;
}
static int scope_lookup(const Scope *s, const char *name, size_t name_len) {
    /* Innermost binding wins → scan backwards. */
    for (int i = s->count - 1; i >= 0; i--) {
        if (s->items[i].name_len == name_len &&
            memcmp(s->items[i].name, name, name_len) == 0) {
            return s->items[i].slot;
        }
    }
    return -1;
}

/* ============================================================ */

typedef struct {
    const TokenList *toks;
    size_t pos;
    NodePool *pool;
    Scope scope;
    char error[256];
    int ok;
} Parser;

static const Token *peek(Parser *p) { return &p->toks->items[p->pos]; }
static const Token *peek_at(Parser *p, size_t off) {
    size_t i = p->pos + off;
    if (i >= p->toks->count) i = p->toks->count - 1;
    return &p->toks->items[i];
}
static const Token *advance(Parser *p) { return &p->toks->items[p->pos++]; }

static void set_error(Parser *p, const char *msg) {
    if (!p->ok) return;
    snprintf(p->error, sizeof(p->error), "line %d: %s", peek(p)->line, msg);
    p->ok = 0;
}

static int match(Parser *p, TokKind k) {
    if (peek(p)->kind == k) { advance(p); return 1; }
    return 0;
}
static int expect(Parser *p, TokKind k, const char *what) {
    if (match(p, k)) return 1;
    char buf[160];
    snprintf(buf, sizeof(buf), "expected %s, got %s", what, tok_kind_name(peek(p)->kind));
    set_error(p, buf);
    return 0;
}

/* ============================================================
 * Expression parsing (Pratt). Returns NULL on error.
 * Operator precedence table mirrors Lua 5.5 §3.4.8 (unchanged from 5.4):
 *   or
 *   and
 *   <  >  <=  >=  ~=  ==
 *   ..
 *   +  -
 *   *  /  //  %
 *   unary (- not #)
 *   ^   (right-assoc, higher than unary)
 * ============================================================ */

#define PREC_NONE   0
#define PREC_OR     1
#define PREC_AND    2
#define PREC_CMP    3
#define PREC_CONCAT 4
#define PREC_ADD    5
#define PREC_MUL    6
#define PREC_UNARY  7
#define PREC_POW    8

static int prec_of(TokKind k) {
    switch (k) {
        case TOK_KW_OR: return PREC_OR;
        case TOK_KW_AND: return PREC_AND;
        case TOK_EQ: case TOK_NEQ: case TOK_LT: case TOK_LE:
        case TOK_GT: case TOK_GE: return PREC_CMP;
        case TOK_CONCAT: return PREC_CONCAT;
        case TOK_PLUS: case TOK_MINUS: return PREC_ADD;
        case TOK_STAR: case TOK_SLASH: case TOK_DSLASH: case TOK_PERCENT: return PREC_MUL;
        case TOK_CARET: return PREC_POW;
        default: return PREC_NONE;
    }
}

static BinOp binop_of(TokKind k) {
    switch (k) {
        case TOK_PLUS:    return BIN_ADD;
        case TOK_MINUS:   return BIN_SUB;
        case TOK_STAR:    return BIN_MUL;
        case TOK_SLASH:   return BIN_DIV;
        case TOK_DSLASH:  return BIN_FDIV;
        case TOK_PERCENT: return BIN_MOD;
        case TOK_CARET:   return BIN_POW;
        case TOK_CONCAT:  return BIN_CONCAT;
        case TOK_EQ:      return BIN_EQ;
        case TOK_NEQ:     return BIN_NEQ;
        case TOK_LT:      return BIN_LT;
        case TOK_LE:      return BIN_LE;
        case TOK_GT:      return BIN_GT;
        case TOK_GE:      return BIN_GE;
        case TOK_KW_AND:  return BIN_AND;
        case TOK_KW_OR:   return BIN_OR;
        default:          return BIN_ADD;
    }
}

static Expr *parse_expr(Parser *p);
static Expr *parse_prec(Parser *p, int min_prec);

static Expr *parse_primary(Parser *p) {
    const Token *t = peek(p);
    int line = t->line;
    switch (t->kind) {
        case TOK_KW_NIL:   advance(p); return expr_new(p->pool, EXPR_NIL,   line);
        case TOK_KW_TRUE:  advance(p); return expr_new(p->pool, EXPR_TRUE,  line);
        case TOK_KW_FALSE: advance(p); return expr_new(p->pool, EXPR_FALSE, line);
        case TOK_INT: {
            advance(p);
            Expr *e = expr_new(p->pool, EXPR_INT, line);
            e->as.i_val = t->i_val;
            return e;
        }
        case TOK_FLOAT: {
            advance(p);
            Expr *e = expr_new(p->pool, EXPR_FLOAT, line);
            e->as.f_val = t->f_val;
            return e;
        }
        case TOK_STRING: {
            advance(p);
            Expr *e = expr_new(p->pool, EXPR_STRING, line);
            e->as.s.bytes = t->str_buf;
            e->as.s.len = t->str_len;
            return e;
        }
        case TOK_IDENT: {
            advance(p);
            Expr *e = expr_new(p->pool, EXPR_VAR, line);
            e->as.var.name = t->start;
            e->as.var.name_len = t->len;
            /* Resolve eagerly: locals first, else builtin (print). */
            int slot = scope_lookup(&p->scope, t->start, t->len);
            if (slot >= 0) {
                e->as.var.local_idx = slot;
            } else if (t->len == 5 && memcmp(t->start, "print", 5) == 0) {
                e->as.var.local_idx = -2;
            } else {
                char buf[160];
                snprintf(buf, sizeof(buf), "undefined variable `%.*s` (v2 supports only locals + builtin print)",
                         (int)t->len, t->start);
                set_error(p, buf);
                return NULL;
            }
            return e;
        }
        case TOK_LPAREN: {
            advance(p);
            Expr *inner = parse_expr(p);
            expect(p, TOK_RPAREN, ")");
            return inner;
        }
        default:
            set_error(p, "expected expression");
            return NULL;
    }
}

static Expr *parse_unary(Parser *p) {
    const Token *t = peek(p);
    int line = t->line;
    UnOp op;
    if (t->kind == TOK_MINUS)        op = UN_NEG;
    else if (t->kind == TOK_KW_NOT)  op = UN_NOT;
    else if (t->kind == TOK_HASH)    op = UN_LEN;
    else {
        Expr *e = parse_primary(p);
        if (!p->ok) return NULL;
        /* postfix: call suffix */
        while (peek(p)->kind == TOK_LPAREN) {
            advance(p);
            Expr *args_buf[16];
            size_t nargs = 0;
            if (peek(p)->kind != TOK_RPAREN) {
                do {
                    if (nargs >= 16) { set_error(p, "too many args (>16) in v2"); return NULL; }
                    args_buf[nargs++] = parse_expr(p);
                    if (!p->ok) return NULL;
                } while (match(p, TOK_COMMA));
            }
            expect(p, TOK_RPAREN, ")");
            Expr *call = expr_new(p->pool, EXPR_CALL, line);
            call->as.call.callee = e;
            call->as.call.nargs = nargs;
            call->as.call.args = node_pool_alloc(p->pool, sizeof(Expr *) * (nargs ? nargs : 1));
            for (size_t i = 0; i < nargs; i++) call->as.call.args[i] = args_buf[i];
            e = call;
        }
        return e;
    }
    advance(p);
    Expr *operand = parse_prec(p, PREC_UNARY);
    if (!p->ok) return NULL;
    Expr *e = expr_new(p->pool, EXPR_UNOP, line);
    e->as.unop.op = op;
    e->as.unop.operand = operand;
    return e;
}

static Expr *parse_prec(Parser *p, int min_prec) {
    Expr *lhs = parse_unary(p);
    if (!p->ok) return NULL;
    while (1) {
        TokKind k = peek(p)->kind;
        int prec = prec_of(k);
        if (prec < min_prec) break;
        int line = peek(p)->line;
        advance(p);
        /* `..` and `^` are right-associative; everything else left. */
        int next_min = (k == TOK_CONCAT || k == TOK_CARET) ? prec : prec + 1;
        Expr *rhs = parse_prec(p, next_min);
        if (!p->ok) return NULL;
        Expr *n = expr_new(p->pool, EXPR_BINOP, line);
        n->as.binop.op = binop_of(k);
        n->as.binop.lhs = lhs;
        n->as.binop.rhs = rhs;
        lhs = n;
    }
    return lhs;
}

static Expr *parse_expr(Parser *p) { return parse_prec(p, PREC_OR); }

/* ============================================================ */

static void parse_block(Parser *p, Block *out, TokKind stop1, TokKind stop2, TokKind stop3);

static int is_block_end(TokKind k, TokKind s1, TokKind s2, TokKind s3) {
    return k == TOK_EOF || k == s1 || k == s2 || k == s3;
}

static Stmt *parse_local(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* local */
    if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected identifier after `local`"); return NULL; }
    const Token *name = advance(p);
    Expr *init = NULL;
    if (match(p, TOK_ASSIGN)) {
        init = parse_expr(p);
        if (!p->ok) return NULL;
    }
    /* Declare AFTER evaluating init so `local x = x` refers to outer x. */
    int slot = scope_declare(&p->scope, name->start, name->len);
    if (slot < 0) { set_error(p, "too many locals"); return NULL; }
    Stmt *s = stmt_new(p->pool, STMT_LOCAL, line);
    s->as.local.name = name->start;
    s->as.local.name_len = name->len;
    s->as.local.init = init;
    s->as.local.local_idx = slot;
    return s;
}

static Stmt *parse_if(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* if */
    /* Collect arms in a vector. */
    IfArm arms_buf[16];
    size_t narms = 0;
    Expr *cond = parse_expr(p);
    if (!p->ok) return NULL;
    expect(p, TOK_KW_THEN, "then");
    Block body = {0};
    int mark = scope_mark(&p->scope);
    parse_block(p, &body, TOK_KW_ELSE, TOK_KW_ELSEIF, TOK_KW_END);
    scope_rewind(&p->scope, mark);
    if (!p->ok) return NULL;
    arms_buf[narms++] = (IfArm){ .cond = cond, .body = body };

    while (peek(p)->kind == TOK_KW_ELSEIF) {
        advance(p);
        Expr *c = parse_expr(p);
        if (!p->ok) return NULL;
        expect(p, TOK_KW_THEN, "then");
        Block b = {0};
        int m = scope_mark(&p->scope);
        parse_block(p, &b, TOK_KW_ELSE, TOK_KW_ELSEIF, TOK_KW_END);
        scope_rewind(&p->scope, m);
        if (!p->ok) return NULL;
        if (narms >= 16) { set_error(p, "too many elseif arms"); return NULL; }
        arms_buf[narms++] = (IfArm){ .cond = c, .body = b };
    }

    int has_else = 0;
    Block else_body = {0};
    if (match(p, TOK_KW_ELSE)) {
        has_else = 1;
        int m = scope_mark(&p->scope);
        parse_block(p, &else_body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
        scope_rewind(&p->scope, m);
        if (!p->ok) return NULL;
    }
    expect(p, TOK_KW_END, "end (of if)");

    Stmt *s = stmt_new(p->pool, STMT_IF, line);
    s->as.if_stmt.narms = narms;
    s->as.if_stmt.arms = node_pool_alloc(p->pool, sizeof(IfArm) * narms);
    for (size_t i = 0; i < narms; i++) s->as.if_stmt.arms[i] = arms_buf[i];
    s->as.if_stmt.has_else = has_else;
    s->as.if_stmt.else_body = else_body;
    return s;
}

static Stmt *parse_while(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* while */
    Expr *cond = parse_expr(p);
    if (!p->ok) return NULL;
    expect(p, TOK_KW_DO, "do");
    Block body = {0};
    int mark = scope_mark(&p->scope);
    parse_block(p, &body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
    scope_rewind(&p->scope, mark);
    expect(p, TOK_KW_END, "end (of while)");
    if (!p->ok) return NULL;
    Stmt *s = stmt_new(p->pool, STMT_WHILE, line);
    s->as.while_stmt.cond = cond;
    s->as.while_stmt.body = body;
    return s;
}

static Stmt *parse_do(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* do */
    Block body = {0};
    int mark = scope_mark(&p->scope);
    parse_block(p, &body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
    scope_rewind(&p->scope, mark);
    expect(p, TOK_KW_END, "end (of do)");
    if (!p->ok) return NULL;
    Stmt *s = stmt_new(p->pool, STMT_DO, line);
    s->as.do_stmt.body = body;
    return s;
}

static Stmt *parse_return(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* return */
    /* v2: support `return` with no value (no-op). */
    /* Accept an optional trailing ; */
    match(p, TOK_SEMI);
    Stmt *s = stmt_new(p->pool, STMT_RETURN, line);
    return s;
}

/* Statement starting with an identifier: either assignment or expr-stmt (call). */
static Stmt *parse_ident_stmt(Parser *p) {
    int line = peek(p)->line;
    /* Look ahead: IDENT ASSIGN ... is assignment; otherwise expression-stmt. */
    if (peek_at(p, 1)->kind == TOK_ASSIGN) {
        const Token *name = advance(p);
        advance(p); /* = */
        int slot = scope_lookup(&p->scope, name->start, name->len);
        if (slot < 0) {
            char buf[160];
            snprintf(buf, sizeof(buf), "assigning to undefined variable `%.*s` (v2: locals only)",
                     (int)name->len, name->start);
            set_error(p, buf);
            return NULL;
        }
        Expr *value = parse_expr(p);
        if (!p->ok) return NULL;
        Stmt *s = stmt_new(p->pool, STMT_ASSIGN, line);
        s->as.assign.name = name->start;
        s->as.assign.name_len = name->len;
        s->as.assign.value = value;
        s->as.assign.local_idx = slot;
        return s;
    }
    /* Expression statement. Must yield a call (Lua disallows bare exprs). */
    Expr *e = parse_expr(p);
    if (!p->ok) return NULL;
    if (e->kind != EXPR_CALL) {
        set_error(p, "expression statement must be a function call");
        return NULL;
    }
    Stmt *s = stmt_new(p->pool, STMT_EXPR, line);
    s->as.expr_stmt.expr = e;
    return s;
}

static Stmt *parse_stmt(Parser *p) {
    switch (peek(p)->kind) {
        case TOK_SEMI: advance(p); return NULL; /* empty stmt */
        case TOK_KW_LOCAL:  return parse_local(p);
        case TOK_KW_IF:     return parse_if(p);
        case TOK_KW_WHILE:  return parse_while(p);
        case TOK_KW_DO:     return parse_do(p);
        case TOK_KW_RETURN: return parse_return(p);
        case TOK_IDENT:     return parse_ident_stmt(p);
        default:
            set_error(p, "expected a statement");
            return NULL;
    }
}

static void parse_block(Parser *p, Block *out, TokKind s1, TokKind s2, TokKind s3) {
    Stmt **vec = NULL;
    size_t count = 0, cap = 0;
    while (p->ok && !is_block_end(peek(p)->kind, s1, s2, s3)) {
        Stmt *st = parse_stmt(p);
        if (!p->ok) break;
        if (!st) continue; /* empty stmt */
        if (count == cap) { cap = cap ? cap * 2 : 8; vec = realloc(vec, cap * sizeof(Stmt *)); }
        vec[count++] = st;
    }
    /* Block bodies live in the AST pool as a copy; the realloc'd buffer is freed below. */
    out->count = count;
    if (count) {
        out->items = node_pool_alloc(p->pool, sizeof(Stmt *) * count);
        memcpy(out->items, vec, sizeof(Stmt *) * count);
    } else {
        out->items = NULL;
    }
    free(vec);
}

ParseResult parse(const TokenList *tokens, NodePool *pool) {
    Parser p = { .toks = tokens, .pool = pool, .ok = 1 };
    scope_init(&p.scope);

    Block program = {0};
    parse_block(&p, &program, TOK_EOF, TOK_EOF, TOK_EOF);

    ParseResult r = {0};
    r.ok = p.ok;
    r.program = program;
    r.max_locals = p.scope.next_slot;
    if (!p.ok) memcpy(r.error, p.error, sizeof(r.error));
    return r;
}
