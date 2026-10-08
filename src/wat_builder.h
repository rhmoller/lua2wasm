#ifndef LUA2WASM_WAT_BUILDER_H
#define LUA2WASM_WAT_BUILDER_H

#include <stdarg.h>
#include <stddef.h>

typedef struct {
    char *buf;
    size_t used;
    size_t cap;
} WatBuilder;

void wat_init(WatBuilder *w);
void wat_free(WatBuilder *w);
void wat_append(WatBuilder *w, const char *s);
[[gnu::format(printf, 2, 3)]] void wat_appendf(WatBuilder *w, const char *fmt, ...);
[[gnu::format(printf, 2, 0)]] void wat_vappendf(WatBuilder *w, const char *fmt, va_list ap);
const char *wat_cstr(const WatBuilder *w);

#endif
