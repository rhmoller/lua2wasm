#ifndef LUA2WASM_PARSER_H
#define LUA2WASM_PARSER_H

#include "ast.h"
#include "lexer.h"

typedef struct {
    LuaNode **items;
    size_t count;
} Program;

typedef struct {
    Program program;
    char error[256];
    int ok;
} ParseResult;

ParseResult parse(const TokenList *tokens, NodePool *pool);
void program_free(Program *p);

#endif
