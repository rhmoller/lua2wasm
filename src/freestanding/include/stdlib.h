/* Freestanding <stdlib.h> — the subset the compiler + vendored dtoa.c use.
 * malloc/calloc/realloc/free are in alloc.c; strtod is provided by the
 * vendored dtoa.c; strtoll + abort/exit live in baselib.c. */
#ifndef _STDLIB_H
#define _STDLIB_H

#include <stddef.h>

void *malloc(size_t n);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *p, size_t n);
void free(void *p);

_Noreturn void abort(void);
_Noreturn void exit(int status);

double strtod(const char *__restrict s, char **__restrict end);
long long strtoll(const char *__restrict s, char **__restrict end, int base);

#endif /* _STDLIB_H */
