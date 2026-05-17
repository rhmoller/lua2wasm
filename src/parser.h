#ifndef LUA2WASM_PARSER_H
#define LUA2WASM_PARSER_H

#include "ast.h"
#include "lexer.h"

typedef struct {
    LuaFunc **items;        /* all user-defined functions, in declaration order */
    size_t count;
} FuncTable;

typedef struct {
    Block main_body;
    int main_n_locals;
    FuncTable funcs;
    char error[256];
    int ok;
} ParseResult;

ParseResult parse(const TokenList *tokens, NodePool *pool);
void parse_result_free(ParseResult *r);

#endif
