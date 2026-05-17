#ifndef LUA2WASM_PARSER_H
#define LUA2WASM_PARSER_H

#include "ast.h"
#include "lexer.h"

typedef struct {
    Block program;          /* top-level block of statements */
    int max_locals;         /* total wasm locals needed for the chunk */
    char error[256];
    int ok;
} ParseResult;

ParseResult parse(const TokenList *tokens, NodePool *pool);

#endif
