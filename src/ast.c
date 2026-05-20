#include "ast.h"
#include "xalloc.h"
#include <stdlib.h>
#include <string.h>

struct PoolChunk {
    PoolChunk *next;
    size_t used;
    size_t cap;
    /* Flexible array member follows. */
    char data[];
};

#define POOL_CHUNK_BYTES 8192

void node_pool_init(NodePool *p) {
    p->chunks = NULL;
}

void node_pool_free(NodePool *p) {
    PoolChunk *c = p->chunks;
    while (c) {
        PoolChunk *next = c->next;
        free(c);
        c = next;
    }
    p->chunks = NULL;
}

void *node_pool_alloc(NodePool *p, size_t bytes) {
    size_t aligned = (bytes + 7u) & ~(size_t)7u;
    PoolChunk *c = p->chunks;
    if (!c || c->used + aligned > c->cap) {
        /* Need a new chunk. Pick max(default size, requested) so any single
         * request fits. Chunks are never realloc'd, so returned pointers
         * remain stable for the lifetime of the pool. */
        size_t cap = aligned > POOL_CHUNK_BYTES ? aligned : POOL_CHUNK_BYTES;
        c = xmalloc(sizeof(PoolChunk) + cap);
        c->next = p->chunks;
        c->used = 0;
        c->cap = cap;
        p->chunks = c;
    }
    void *ptr = c->data + c->used;
    c->used += aligned;
    memset(ptr, 0, aligned);
    return ptr;
}

Expr *expr_new(NodePool *p, ExprKind k, int line) {
    Expr *e = node_pool_alloc(p, sizeof(Expr));
    e->kind = k;
    e->line = line;
    e->paren = 0;
    return e;
}

Stmt *stmt_new(NodePool *p, StmtKind k, int line) {
    Stmt *s = node_pool_alloc(p, sizeof(Stmt));
    s->kind = k;
    s->line = line;
    return s;
}

LuaFunc *func_new(NodePool *p, int func_idx, int line) {
    LuaFunc *f = node_pool_alloc(p, sizeof(LuaFunc));
    f->func_idx = func_idx;
    f->line = line;
    return f;
}
