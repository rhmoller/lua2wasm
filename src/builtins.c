#include "builtins.h"
#include <string.h>

/* The order here defines the $g_builtin_N global indices used at runtime.
 * Adding a builtin requires:
 *   (1) adding an entry here,
 *   (2) defining $builtin_NAME in the codegen prelude with type $LuaFn. */
static const struct {
    const char *name;
    size_t      len;
    const char *func_name;
} BUILTINS[] = {
    { "print", 5, "$builtin_print" },
    { "error", 5, "$builtin_error" },
    { "pcall", 5, "$builtin_pcall" },
};

#define N (sizeof(BUILTINS)/sizeof(BUILTINS[0]))

int lookup_builtin(const char *name, size_t name_len) {
    for (size_t i = 0; i < N; i++) {
        if (BUILTINS[i].len == name_len &&
            memcmp(BUILTINS[i].name, name, name_len) == 0) return (int)i;
    }
    return -1;
}

int builtin_count(void) { return (int)N; }
const char *builtin_name(int idx) { return BUILTINS[idx].name; }
const char *builtin_func_name(int idx) { return BUILTINS[idx].func_name; }
