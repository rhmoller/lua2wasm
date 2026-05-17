#ifndef LUA2WASM_AST_H
#define LUA2WASM_AST_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    NODE_NUMBER,
    NODE_IDENT,
    NODE_CALL,
    NODE_BINOP,
} LuaNodeKind;

typedef enum {
    BINOP_ADD,
    BINOP_SUB,
    BINOP_MUL,
    BINOP_DIV,
} LuaBinOp;

typedef struct LuaNode LuaNode;

struct LuaNode {
    LuaNodeKind kind;
    union {
        struct { int64_t value; } number;
        struct { const char *name; size_t len; } ident;
        struct { LuaNode *callee; LuaNode **args; size_t nargs; } call;
        struct { LuaBinOp op; LuaNode *lhs; LuaNode *rhs; } binop;
    } as;
};

typedef struct {
    char *buf;
    size_t used;
    size_t cap;
} NodePool;

void node_pool_init(NodePool *p);
void node_pool_free(NodePool *p);
void *node_pool_alloc(NodePool *p, size_t bytes);
LuaNode *node_new(NodePool *p, LuaNodeKind k);

#endif
