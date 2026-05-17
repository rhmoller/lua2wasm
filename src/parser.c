#include "parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const TokenList *toks;
    size_t pos;
    NodePool *pool;
    char error[256];
    int ok;
} Parser;

static const Token *peek(Parser *p) { return &p->toks->items[p->pos]; }
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
    char buf[128];
    snprintf(buf, sizeof(buf), "expected %s, got %s", what, tok_kind_name(peek(p)->kind));
    set_error(p, buf);
    return 0;
}

static LuaNode *parse_expr(Parser *p);

static LuaNode *parse_primary(Parser *p) {
    const Token *t = peek(p);
    if (t->kind == TOK_NUMBER) {
        advance(p);
        LuaNode *n = node_new(p->pool, NODE_NUMBER);
        n->as.number.value = t->number;
        return n;
    }
    if (t->kind == TOK_IDENT) {
        advance(p);
        LuaNode *n = node_new(p->pool, NODE_IDENT);
        n->as.ident.name = t->start;
        n->as.ident.len = t->len;
        return n;
    }
    if (t->kind == TOK_LPAREN) {
        advance(p);
        LuaNode *inner = parse_expr(p);
        expect(p, TOK_RPAREN, ")");
        return inner;
    }
    set_error(p, "expected expression");
    return NULL;
}

/* call suffix: primary followed by optional (args, ...) */
static LuaNode *parse_postfix(Parser *p) {
    LuaNode *expr = parse_primary(p);
    if (!p->ok) return NULL;

    while (peek(p)->kind == TOK_LPAREN) {
        advance(p); /* ( */
        LuaNode *args_buf[16];
        size_t nargs = 0;
        if (peek(p)->kind != TOK_RPAREN) {
            do {
                if (nargs >= 16) { set_error(p, "too many args (>16) in v1"); return NULL; }
                args_buf[nargs++] = parse_expr(p);
                if (!p->ok) return NULL;
            } while (match(p, TOK_COMMA));
        }
        expect(p, TOK_RPAREN, ")");

        LuaNode *call = node_new(p->pool, NODE_CALL);
        call->as.call.callee = expr;
        call->as.call.nargs = nargs;
        call->as.call.args = node_pool_alloc(p->pool, sizeof(LuaNode *) * (nargs ? nargs : 1));
        for (size_t i = 0; i < nargs; i++) call->as.call.args[i] = args_buf[i];
        expr = call;
    }
    return expr;
}

/* Pratt: precedence 1 = +/-, 2 = */ /* */
static int prec_of(TokKind k) {
    switch (k) {
        case TOK_PLUS: case TOK_MINUS: return 1;
        case TOK_STAR: case TOK_SLASH: return 2;
        default: return 0;
    }
}

static LuaBinOp binop_of(TokKind k) {
    switch (k) {
        case TOK_PLUS: return BINOP_ADD;
        case TOK_MINUS: return BINOP_SUB;
        case TOK_STAR: return BINOP_MUL;
        case TOK_SLASH: return BINOP_DIV;
        default: return BINOP_ADD;
    }
}

static LuaNode *parse_binop(Parser *p, int min_prec) {
    LuaNode *lhs = parse_postfix(p);
    if (!p->ok) return NULL;
    while (1) {
        int prec = prec_of(peek(p)->kind);
        if (prec < min_prec) break;
        TokKind op_kind = peek(p)->kind;
        advance(p);
        LuaNode *rhs = parse_binop(p, prec + 1);
        if (!p->ok) return NULL;
        LuaNode *n = node_new(p->pool, NODE_BINOP);
        n->as.binop.op = binop_of(op_kind);
        n->as.binop.lhs = lhs;
        n->as.binop.rhs = rhs;
        lhs = n;
    }
    return lhs;
}

static LuaNode *parse_expr(Parser *p) {
    return parse_binop(p, 1);
}

ParseResult parse(const TokenList *tokens, NodePool *pool) {
    Parser p = { .toks = tokens, .pool = pool, .ok = 1 };

    LuaNode **stmts = NULL;
    size_t count = 0, cap = 0;

    while (peek(&p)->kind != TOK_EOF) {
        LuaNode *stmt = parse_expr(&p);
        if (!p.ok) break;
        if (count == cap) {
            cap = cap ? cap * 2 : 8;
            stmts = realloc(stmts, cap * sizeof(LuaNode *));
        }
        stmts[count++] = stmt;
    }

    ParseResult r = {0};
    r.ok = p.ok;
    r.program.items = stmts;
    r.program.count = count;
    if (!p.ok) memcpy(r.error, p.error, sizeof(r.error));
    return r;
}

void program_free(Program *p) {
    free(p->items);
    p->items = NULL;
    p->count = 0;
}
