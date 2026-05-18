#ifndef LUA2WASM_XALLOC_H
#define LUA2WASM_XALLOC_H

#include <stddef.h>

/* Allocation wrappers that abort with a useful diagnostic on OOM instead
 * of returning NULL. The compiler runs as a short-lived batch process — no
 * sensible recovery exists, and the existing code paths assume the returns
 * are non-null. Centralising the check keeps it easy to switch to a
 * recovery strategy later (e.g. setjmp/longjmp out to the CLI). */
void *xmalloc(size_t n);
void *xrealloc(void *p, size_t n);

#endif
