#ifndef LUA2WASM_BUILTINS_H
#define LUA2WASM_BUILTINS_H

#include <stddef.h>

/* Returns the builtin index for `name`, or -1 if not a builtin.
 * Indices correspond to $g_builtin_N globals emitted by codegen. */
int lookup_builtin(const char *name, size_t name_len);

/* Number of builtins. */
int builtin_count(void);

/* Builtin name and the C-symbol-safe stub name (e.g. "print" / "$builtin_print").
 * The codegen emits the dispatch globals using these. */
const char *builtin_name(int idx);
const char *builtin_func_name(int idx);

#endif
