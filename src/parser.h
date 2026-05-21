#ifndef LUA2WASM_PARSER_H
#define LUA2WASM_PARSER_H

#include "ast.h"
#include "lexer.h"

typedef struct {
    LuaFunc **items; /* all user-defined functions, in declaration order */
    size_t count;
} FuncTable;

typedef struct {
    const char *name;
    size_t name_len;
} GlobalDecl;

typedef struct {
    GlobalDecl *items;
    size_t count;
} GlobalTable;

typedef struct {
    Block main_body;
    int main_n_locals;
    /* Escape-analysis bitmap for top-level locals; see LuaFunc.captured. */
    unsigned char *main_captured;
    FuncTable funcs;
    GlobalTable globals;
    char error[256];
    int ok;
} ParseResult;

ParseResult parse(const TokenList *tokens, NodePool *pool);
void parse_result_free(ParseResult *r);

#endif
