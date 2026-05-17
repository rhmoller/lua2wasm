#ifndef LUA2WASM_LEXER_H
#define LUA2WASM_LEXER_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    TOK_EOF,
    TOK_IDENT,
    TOK_NUMBER,
    TOK_LPAREN,
    TOK_RPAREN,
    TOK_PLUS,
    TOK_MINUS,
    TOK_STAR,
    TOK_SLASH,
    TOK_COMMA,
    TOK_ERROR,
} TokKind;

typedef struct {
    TokKind kind;
    const char *start;
    size_t len;
    int64_t number;
    int line;
} Token;

typedef struct {
    Token *items;
    size_t count;
} TokenList;

TokenList lex(const char *source);
void tokenlist_free(TokenList *t);
const char *tok_kind_name(TokKind k);

#endif
