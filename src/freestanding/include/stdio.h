/* Freestanding <stdio.h> — only the formatted-output subset the compiler
 * uses: snprintf/vsnprintf for building WAT, and fprintf(stderr, ...) for
 * diagnostics (routed to the host `log` import). There is no real FILE; the
 * stream argument to fprintf is ignored. Implementations live in fmt.c. */
#ifndef _STDIO_H
#define _STDIO_H

#include <stddef.h>
#include <stdarg.h>

typedef struct _FILE FILE;
extern FILE *stderr;
extern FILE *stdout;

int snprintf(char *__restrict buf, size_t n, const char *__restrict fmt, ...)
    __attribute__((format(printf, 3, 4)));
int vsnprintf(char *__restrict buf, size_t n, const char *__restrict fmt, va_list ap)
    __attribute__((format(printf, 3, 0)));
int fprintf(FILE *stream, const char *__restrict fmt, ...)
    __attribute__((format(printf, 2, 3)));

#endif /* _STDIO_H */
