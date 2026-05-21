#include "wat_builder.h"
#include "xalloc.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void wat_init(WatBuilder *w) {
    w->cap = 1024;
    w->buf = xmalloc(w->cap);
    w->buf[0] = '\0';
    w->used = 0;
}

void wat_free(WatBuilder *w) {
    free(w->buf);
    w->buf = NULL;
    w->cap = w->used = 0;
}

static void ensure(WatBuilder *w, size_t need) {
    if (w->used + need + 1 > w->cap) {
        while (w->used + need + 1 > w->cap) w->cap *= 2;
        w->buf = xrealloc(w->buf, w->cap);
    }
}

void wat_append(WatBuilder *w, const char *s) {
    size_t n = strlen(s);
    ensure(w, n);
    memcpy(w->buf + w->used, s, n);
    w->used += n;
    w->buf[w->used] = '\0';
}

void wat_appendf(WatBuilder *w, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list ap2;
    va_copy(ap2, ap);
    int needed = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (needed < 0) {
        /* A negative return from vsnprintf is an encoding error — a
         * programming bug in the format string, not a recoverable
         * condition. Silently returning would emit a corrupt WAT file,
         * so abort with a diagnostic (matching the xalloc convention). */
        va_end(ap2);
        fprintf(stderr, "lua2wasm: wat_appendf: vsnprintf failed for format \"%s\"\n", fmt);
        abort();
    }
    ensure(w, (size_t)needed);
    vsnprintf(w->buf + w->used, w->cap - w->used, fmt, ap2);
    va_end(ap2);
    w->used += (size_t)needed;
}

const char *wat_cstr(const WatBuilder *w) { return w->buf; }
