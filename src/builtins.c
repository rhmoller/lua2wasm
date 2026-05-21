#include "builtins.h"
#include <string.h>

/* Keep the hand-aligned builtin table — clang-format can't reproduce it. */
/* clang-format off */
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
    { "xpcall",   6, "$builtin_xpcall",   BLT_TOPLEVEL },
    { "warn",     4, "$builtin_warn",     BLT_TOPLEVEL },
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
    /* iterator helper for utf8.codes — same trick: leading underscore
     * keeps it out of user-facing lookups while still creating the
     * \$g_builtin_utf8_codes_iter global. */
    { "_utf8_codes_iter", 16, "$builtin_utf8_codes_iter", BLT_TOPLEVEL },
    { "require", 7, "$builtin_require", BLT_TOPLEVEL },
    /* Stubs for names common in the upstream test suite. lua2wasm leans
     * on the host (V8/SpiderMonkey) GC and has no runtime compiler, so
     * these can't do their real jobs — but returning spec-shaped values
     * keeps programs that probe for these names from blowing up. */
    { "collectgarbage", 14, "$builtin_collectgarbage", BLT_TOPLEVEL },
    { "load",           4,  "$builtin_load",           BLT_TOPLEVEL },
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
    { "deg",   3, "$builtin_math_deg",   BLT_LIB_MATH },
    { "rad",   3, "$builtin_math_rad",   BLT_LIB_MATH },
    { "fmod",  4, "$builtin_math_fmod",  BLT_LIB_MATH },
    { "modf",  4, "$builtin_math_modf",  BLT_LIB_MATH },
    { "tointeger", 9, "$builtin_math_tointeger", BLT_LIB_MATH },
    { "type",  4, "$builtin_math_type",  BLT_LIB_MATH },
    { "ult",   3, "$builtin_math_ult",   BLT_LIB_MATH },
    { "random",     6,  "$builtin_math_random",     BLT_LIB_MATH },
    { "randomseed", 10, "$builtin_math_randomseed", BLT_LIB_MATH },
    /* string library */
    { "len",    3, "$builtin_string_len",    BLT_LIB_STRING },
    { "sub",    3, "$builtin_string_sub",    BLT_LIB_STRING },
    { "format", 6, "$builtin_string_format", BLT_LIB_STRING },
    { "upper",  5, "$builtin_string_upper",  BLT_LIB_STRING },
    { "lower",  5, "$builtin_string_lower",  BLT_LIB_STRING },
    { "reverse",7, "$builtin_string_reverse",BLT_LIB_STRING },
    { "rep",    3, "$builtin_string_rep",    BLT_LIB_STRING },
    { "byte",   4, "$builtin_string_byte",   BLT_LIB_STRING },
    { "char",   4, "$builtin_string_char",   BLT_LIB_STRING },
    { "find",   4, "$builtin_string_find",   BLT_LIB_STRING },
    { "match",  5, "$builtin_string_match",  BLT_LIB_STRING },
    { "gmatch", 6, "$builtin_string_gmatch", BLT_LIB_STRING },
    { "gsub",   4, "$builtin_string_gsub",   BLT_LIB_STRING },
    { "packsize", 8, "$builtin_string_packsize", BLT_LIB_STRING },
    { "pack",     4, "$builtin_string_pack",     BLT_LIB_STRING },
    { "unpack",   6, "$builtin_string_unpack",   BLT_LIB_STRING },
    /* utf8 library */
    { "char",   4, "$builtin_utf8_char",   BLT_LIB_UTF8 },
    { "len",    3, "$builtin_utf8_len",    BLT_LIB_UTF8 },
    { "codepoint", 9, "$builtin_utf8_codepoint", BLT_LIB_UTF8 },
    { "offset",    6, "$builtin_utf8_offset",    BLT_LIB_UTF8 },
    { "codes",     5, "$builtin_utf8_codes",     BLT_LIB_UTF8 },
    /* io library */
    { "write",  5, "$builtin_io_write",  BLT_LIB_IO },
    { "read",   4, "$builtin_io_read",   BLT_LIB_IO },
    { "open",   4, "$builtin_io_open",   BLT_LIB_IO },
    { "lines",  5, "$builtin_io_lines",  BLT_LIB_IO },
    { "type",   4, "$io_type",           BLT_LIB_IO },
    { "output", 6, "$builtin_io_output", BLT_LIB_IO },
    { "input",  5, "$builtin_io_input",  BLT_LIB_IO },
    /* File-handle methods. Leading underscore keeps the standard io-table
     * install loop from registering them as io._* keys; codegen emits a
     * dedicated installation step that wires them onto the three stdio
     * handles (io.stdout, io.stderr, io.stdin). */
    { "_handle_write",     13, "$io_handle_write",     BLT_LIB_IO },
    { "_handle_err_write", 17, "$io_handle_err_write", BLT_LIB_IO },
    { "_handle_read",      12, "$io_handle_read",      BLT_LIB_IO },
    { "_handle_noop",      12, "$io_handle_noop",      BLT_LIB_IO },
    /* Real-file-handle methods (created by io.open). Same underscore rule:
     * io.open builds each handle table at runtime and attaches these via
     * their $g_* closure globals, so they're never io.* keys themselves.
     * $builtin_io_open / $builtin_io_lines reference these globals from
     * the always-present prelude, so they're force-lived in codegen. */
    { "_file_read",     10, "$file_read",     BLT_LIB_IO },
    { "_file_write",    11, "$file_write",    BLT_LIB_IO },
    { "_file_close",    11, "$file_close",    BLT_LIB_IO },
    { "_file_flush",    11, "$file_flush",    BLT_LIB_IO },
    { "_file_seek",     10, "$file_seek",     BLT_LIB_IO },
    { "_file_lines",    11, "$file_lines",    BLT_LIB_IO },
    { "_io_lines_iter", 14, "$io_lines_iter", BLT_LIB_IO },
    /* table library */
    { "insert", 6, "$builtin_table_insert", BLT_LIB_TABLE },
    { "remove", 6, "$builtin_table_remove", BLT_LIB_TABLE },
    { "concat", 6, "$builtin_table_concat", BLT_LIB_TABLE },
    { "unpack", 6, "$builtin_table_unpack", BLT_LIB_TABLE },
    { "pack",   4, "$builtin_table_pack",   BLT_LIB_TABLE },
    { "move",   4, "$builtin_table_move",   BLT_LIB_TABLE },
    { "create", 6, "$builtin_table_create", BLT_LIB_TABLE },
    { "sort",   4, "$builtin_table_sort",   BLT_LIB_TABLE },
    /* debug library (milestone 22) */
    { "traceback",    9, "$builtin_debug_traceback",    BLT_LIB_DEBUG },
    { "getmetatable", 12, "$builtin_debug_getmetatable", BLT_LIB_DEBUG },
    { "setmetatable", 12, "$builtin_debug_setmetatable", BLT_LIB_DEBUG },
    { "gethook",      7, "$builtin_debug_gethook",      BLT_LIB_DEBUG },
    /* os library — minimal shims. The host owns wall-clock time,
     * environment variables, and process termination. */
    { "time",    4, "$builtin_os_time",    BLT_LIB_OS },
    { "clock",   5, "$builtin_os_clock",   BLT_LIB_OS },
    { "date",    4, "$builtin_os_date",    BLT_LIB_OS },
    { "getenv",  6, "$builtin_os_getenv",  BLT_LIB_OS },
    { "exit",    4, "$builtin_os_exit",    BLT_LIB_OS },
    { "execute", 7, "$builtin_os_execute", BLT_LIB_OS },
    { "remove",  6, "$builtin_os_remove",  BLT_LIB_OS },
    { "rename",  6, "$builtin_os_rename",  BLT_LIB_OS },
    { "tmpname", 7, "$builtin_os_tmpname", BLT_LIB_OS },
    { "difftime",  8, "$builtin_os_difftime",  BLT_LIB_OS },
    { "setlocale", 9, "$builtin_os_setlocale", BLT_LIB_OS },
};
/* clang-format on */

#define N (sizeof(BUILTINS) / sizeof(BUILTINS[0]))

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
