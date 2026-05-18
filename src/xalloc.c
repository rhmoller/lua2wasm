#include "xalloc.h"
#include <stdio.h>
#include <stdlib.h>

static void die_oom(const char *what, size_t n) {
    fprintf(stderr, "lua2wasm: %s of %zu bytes failed (out of memory)\n", what, n);
    abort();
}

void *xmalloc(size_t n) {
    /* malloc(0) is implementation-defined; round up so the contract is
     * "returns a pointer you can write at least 1 byte to". */
    if (n == 0) n = 1;
    void *p = malloc(n);
    if (!p) die_oom("malloc", n);
    return p;
}

void *xrealloc(void *p, size_t n) {
    if (n == 0) n = 1;
    void *q = realloc(p, n);
    if (!q) die_oom("realloc", n);
    return q;
}
