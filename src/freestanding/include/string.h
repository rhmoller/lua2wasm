/* Freestanding <string.h> — the subset the compiler + vendored dtoa.c use.
 * Implementations live in baselib.c. */
#ifndef _STRING_H
#define _STRING_H

#include <stddef.h>

void *memcpy(void *__restrict dst, const void *__restrict src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strchr(const char *s, int c);
char *strcpy(char *__restrict dst, const char *__restrict src);

#endif /* _STRING_H */
