#include "lexer.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    Token *items;
    size_t count;
    size_t cap;
} TokVec;

static void push_tok(TokVec *v, Token t) {
    if (v->count == v->cap) {
        v->cap = v->cap ? v->cap * 2 : 16;
        v->items = realloc(v->items, v->cap * sizeof(Token));
    }
    v->items[v->count++] = t;
}

TokenList lex(const char *source) {
    TokVec v = {0};
    const char *p = source;
    int line = 1;

    while (*p) {
        if (*p == '\n') { line++; p++; continue; }
        if (isspace((unsigned char)*p)) { p++; continue; }
        if (*p == '-' && p[1] == '-') {
            while (*p && *p != '\n') p++;
            continue;
        }

        Token t = { .start = p, .line = line };

        if (isdigit((unsigned char)*p)) {
            int64_t n = 0;
            const char *s = p;
            while (isdigit((unsigned char)*p)) {
                n = n * 10 + (*p - '0');
                p++;
            }
            t.kind = TOK_NUMBER;
            t.number = n;
            t.len = (size_t)(p - s);
            push_tok(&v, t);
            continue;
        }

        if (isalpha((unsigned char)*p) || *p == '_') {
            const char *s = p;
            while (isalnum((unsigned char)*p) || *p == '_') p++;
            t.kind = TOK_IDENT;
            t.len = (size_t)(p - s);
            push_tok(&v, t);
            continue;
        }

        switch (*p) {
            case '(': t.kind = TOK_LPAREN; t.len = 1; p++; break;
            case ')': t.kind = TOK_RPAREN; t.len = 1; p++; break;
            case '+': t.kind = TOK_PLUS;   t.len = 1; p++; break;
            case '-': t.kind = TOK_MINUS;  t.len = 1; p++; break;
            case '*': t.kind = TOK_STAR;   t.len = 1; p++; break;
            case '/': t.kind = TOK_SLASH;  t.len = 1; p++; break;
            case ',': t.kind = TOK_COMMA;  t.len = 1; p++; break;
            default:  t.kind = TOK_ERROR;  t.len = 1; p++; break;
        }
        push_tok(&v, t);
    }

    Token eof = { .kind = TOK_EOF, .start = p, .len = 0, .line = line };
    push_tok(&v, eof);

    return (TokenList){ .items = v.items, .count = v.count };
}

void tokenlist_free(TokenList *t) {
    free(t->items);
    t->items = NULL;
    t->count = 0;
}

const char *tok_kind_name(TokKind k) {
    switch (k) {
        case TOK_EOF: return "EOF";
        case TOK_IDENT: return "IDENT";
        case TOK_NUMBER: return "NUMBER";
        case TOK_LPAREN: return "(";
        case TOK_RPAREN: return ")";
        case TOK_PLUS: return "+";
        case TOK_MINUS: return "-";
        case TOK_STAR: return "*";
        case TOK_SLASH: return "/";
        case TOK_COMMA: return ",";
        case TOK_ERROR: return "ERROR";
    }
    return "?";
}
