#ifndef LUA2WASM_BUILTINS_H
#define LUA2WASM_BUILTINS_H

#include <stddef.h>

typedef enum {
    BLT_TOPLEVEL,   /* visible as a top-level name (print, type, ...) */
    BLT_LIB_MATH,   /* installed into the `math` global table */
    BLT_LIB_STRING, /* installed into the `string` global table */
    BLT_LIB_IO,     /* installed into the `io` global table */
    BLT_LIB_TABLE,  /* installed into the `table` global table */
    BLT_LIB_UTF8,   /* installed into the `utf8` global table */
    BLT_LIB_DEBUG,  /* installed into the `debug` global table */
    BLT_LIB_OS,     /* installed into the `os` global table */
} BuiltinClass;

/* Lookup a top-level builtin by name. Returns builtin idx or -1. */
int lookup_builtin(const char *name, size_t name_len);

int builtin_count(void);
const char *builtin_name(int idx);
const char *builtin_func_name(int idx);
BuiltinClass builtin_class(int idx);
/* For library entries, the table key under which the function is exposed.
 * (Same as builtin_name for now.) */
const char *builtin_lib_key(int idx);

#endif
