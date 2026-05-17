#ifndef LUA2WASM_WAT_BUILDER_H
#define LUA2WASM_WAT_BUILDER_H

#include <stddef.h>

typedef struct {
    char *buf;
    size_t used;
    size_t cap;
} WatBuilder;

void wat_init(WatBuilder *w);
void wat_free(WatBuilder *w);
void wat_append(WatBuilder *w, const char *s);
void wat_appendf(WatBuilder *w, const char *fmt, ...);
const char *wat_cstr(const WatBuilder *w);

#endif
