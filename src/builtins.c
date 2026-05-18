#include "builtins.h"
#include <string.h>

static const struct {
    const char *name;       /* lookup key (top-level) or table key (libs) */
    size_t      len;
    const char *func_name;  /* wasm function symbol */
    BuiltinClass cls;
} BUILTINS[] = {
    /* top-level */
    { "print",    5, "$builtin_print",    BLT_TOPLEVEL },
    { "error",    5, "$builtin_error",    BLT_TOPLEVEL },
    { "pcall",    5, "$builtin_pcall",    BLT_TOPLEVEL },
    { "type",     4, "$builtin_type",     BLT_TOPLEVEL },
    { "tostring", 8, "$builtin_tostring", BLT_TOPLEVEL },
    { "tonumber", 8, "$builtin_tonumber", BLT_TOPLEVEL },
    { "ipairs",   6, "$builtin_ipairs",   BLT_TOPLEVEL },
    { "pairs",    5, "$builtin_pairs",    BLT_TOPLEVEL },
    { "next",         4,  "$builtin_next",         BLT_TOPLEVEL },
    { "setmetatable", 12, "$builtin_setmetatable", BLT_TOPLEVEL },
    { "getmetatable", 12, "$builtin_getmetatable", BLT_TOPLEVEL },
    { "assert",       6,  "$builtin_assert",       BLT_TOPLEVEL },
    { "select",       6,  "$builtin_select",       BLT_TOPLEVEL },
    { "rawequal",     8,  "$builtin_rawequal",     BLT_TOPLEVEL },
    { "rawlen",       6,  "$builtin_rawlen",       BLT_TOPLEVEL },
    { "rawget",       6,  "$builtin_rawget",       BLT_TOPLEVEL },
    { "rawset",       6,  "$builtin_rawset",       BLT_TOPLEVEL },
    /* iterators for ipairs/pairs (not user-visible by name) */
    { "_ipairs_iter", 12, "$builtin_ipairs_iter", BLT_TOPLEVEL },
    /* math library (installed into the `math` table) */
    { "floor", 5, "$builtin_math_floor", BLT_LIB_MATH },
    { "abs",   3, "$builtin_math_abs",   BLT_LIB_MATH },
    { "sqrt",  4, "$builtin_math_sqrt",  BLT_LIB_MATH },
    { "ceil",  4, "$builtin_math_ceil",  BLT_LIB_MATH },
    { "min",   3, "$builtin_math_min",   BLT_LIB_MATH },
    { "max",   3, "$builtin_math_max",   BLT_LIB_MATH },
    { "sin",   3, "$builtin_math_sin",   BLT_LIB_MATH },
    { "cos",   3, "$builtin_math_cos",   BLT_LIB_MATH },
    { "tan",   3, "$builtin_math_tan",   BLT_LIB_MATH },
    { "asin",  4, "$builtin_math_asin",  BLT_LIB_MATH },
    { "acos",  4, "$builtin_math_acos",  BLT_LIB_MATH },
    { "atan",  4, "$builtin_math_atan",  BLT_LIB_MATH },
    { "exp",   3, "$builtin_math_exp",   BLT_LIB_MATH },
    { "log",   3, "$builtin_math_log",   BLT_LIB_MATH },
    /* string library */
    { "len",    3, "$builtin_string_len",    BLT_LIB_STRING },
    { "sub",    3, "$builtin_string_sub",    BLT_LIB_STRING },
    { "format", 6, "$builtin_string_format", BLT_LIB_STRING },
    /* io library */
    { "write", 5, "$builtin_io_write", BLT_LIB_IO },
    { "read",  4, "$builtin_io_read",  BLT_LIB_IO },
    /* table library */
    { "insert", 6, "$builtin_table_insert", BLT_LIB_TABLE },
    { "remove", 6, "$builtin_table_remove", BLT_LIB_TABLE },
    { "concat", 6, "$builtin_table_concat", BLT_LIB_TABLE },
    { "unpack", 6, "$builtin_table_unpack", BLT_LIB_TABLE },
};

#define N (sizeof(BUILTINS)/sizeof(BUILTINS[0]))

int lookup_builtin(const char *name, size_t name_len) {
    for (size_t i = 0; i < N; i++) {
        if (BUILTINS[i].cls != BLT_TOPLEVEL) continue;
        /* The `_ipairs_iter` entry exists only so codegen can build a closure,
         * not so users can name it. Skip it in lookups. */
        if (BUILTINS[i].name[0] == '_') continue;
        if (BUILTINS[i].len == name_len &&
            memcmp(BUILTINS[i].name, name, name_len) == 0) return (int)i;
    }
    return -1;
}

int builtin_count(void) { return (int)N; }
const char *builtin_name(int idx) { return BUILTINS[idx].name; }
const char *builtin_func_name(int idx) { return BUILTINS[idx].func_name; }
BuiltinClass builtin_class(int idx) { return BUILTINS[idx].cls; }
const char *builtin_lib_key(int idx) { return BUILTINS[idx].name; }
