#include "ast.h"
#include <stdlib.h>
#include <string.h>

void node_pool_init(NodePool *p) {
    p->cap = 4096;
    p->buf = malloc(p->cap);
    p->used = 0;
}

void node_pool_free(NodePool *p) {
    free(p->buf);
    p->buf = NULL;
    p->cap = p->used = 0;
}

void *node_pool_alloc(NodePool *p, size_t bytes) {
    size_t aligned = (bytes + 7u) & ~(size_t)7u;
    if (p->used + aligned > p->cap) {
        size_t new_cap = p->cap * 2;
        while (p->used + aligned > new_cap) new_cap *= 2;
        p->buf = realloc(p->buf, new_cap);
        p->cap = new_cap;
    }
    void *ptr = p->buf + p->used;
    p->used += aligned;
    memset(ptr, 0, aligned);
    return ptr;
}

LuaNode *node_new(NodePool *p, LuaNodeKind k) {
    LuaNode *n = node_pool_alloc(p, sizeof(LuaNode));
    n->kind = k;
    return n;
}
