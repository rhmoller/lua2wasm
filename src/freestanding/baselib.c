/* Freestanding C runtime for the wasm32 build of the compiler: the mem/str
 * primitives, ctype is header-inline, errno, abort/exit, and strtoll. Float
 * <-> string (strtod/dtoa) is the vendored dtoa.c; formatted output is fmt.c;
 * the allocator is alloc.c. Together these are the entire libc surface the
 * compiler core references (see the audit in the freestanding build script). */

#include <stddef.h>
#include <stdint.h>

#include "errno.h"
#include "host.h"

/* --- errno ------------------------------------------------------------- */
int errno = 0;

/* --- process control --------------------------------------------------- */
_Noreturn void abort(void) {
    host_abort();
    __builtin_unreachable();
}

_Noreturn void exit(int status) {
    (void)status;
    host_abort();
    __builtin_unreachable();
}

/* --- memory primitives ------------------------------------------------- *
 * no_builtin("memcpy"/...) stops clang's loop-idiom recognizer from
 * rewriting these naive loops into calls to themselves. */
__attribute__((no_builtin("memcpy"))) void *memcpy(void *__restrict dst,
                                                   const void *__restrict src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

__attribute__((no_builtin("memmove"))) void *memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d == s || n == 0) return dst;
    if (d < s) {
        for (size_t i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (size_t i = n; i-- > 0;) d[i] = s[i];
    }
    return dst;
}

__attribute__((no_builtin("memset"))) void *memset(void *dst, int c, size_t n) {
    unsigned char *d = dst;
    for (size_t i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *p = a, *q = b;
    for (size_t i = 0; i < n; i++) {
        if (p[i] != q[i]) return (int)p[i] - (int)q[i];
    }
    return 0;
}

/* --- string primitives ------------------------------------------------- */
size_t strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char ca = (unsigned char)a[i], cb = (unsigned char)b[i];
        if (ca != cb) return (int)ca - (int)cb;
        if (ca == 0) break;
    }
    return 0;
}

char *strchr(const char *s, int c) {
    char ch = (char)c;
    for (;; s++) {
        if (*s == ch) return (char *)s;
        if (*s == 0) return NULL;
    }
}

char *strcpy(char *__restrict dst, const char *__restrict src) {
    char *d = dst;
    while ((*d++ = *src++)) {
    }
    return dst;
}

/* --- strtoll ----------------------------------------------------------- *
 * Standard semantics: skip leading isspace, optional sign, optional 0x for
 * base 16 / base 0, digit accumulation with overflow clamp to LLONG_MIN/MAX.
 * The lexer is the only caller (integer literals), always with base 10 or 16. */
#define LLONG_MAX 0x7fffffffffffffffLL
#define LLONG_MIN (-LLONG_MAX - 1)

static int digit_val(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return 99;
}

long long strtoll(const char *__restrict s, char **__restrict end, int base) {
    const char *p = s;
    while (*p == ' ' || (*p >= '\t' && *p <= '\r')) p++;

    int neg = 0;
    if (*p == '+' || *p == '-') {
        neg = (*p == '-');
        p++;
    }

    if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X') &&
        digit_val((unsigned char)p[2]) < 16) {
        p += 2;
        base = 16;
    } else if (base == 0) {
        base = (p[0] == '0') ? 8 : 10;
    }

    unsigned long long acc = 0;
    int any = 0, overflow = 0;
    unsigned long long cutoff = neg ? (unsigned long long)LLONG_MIN : (unsigned long long)LLONG_MAX;
    unsigned long long lim = cutoff / (unsigned)base;
    int limd = (int)(cutoff % (unsigned)base);

    for (;; p++) {
        int d = digit_val((unsigned char)*p);
        if (d >= base) break;
        any = 1;
        if (overflow || acc > lim || (acc == lim && d > limd)) {
            overflow = 1;
            continue;
        }
        acc = acc * (unsigned)base + (unsigned)d;
    }

    if (end) *end = (char *)(any ? p : s);
    if (overflow) {
        errno = ERANGE;
        return neg ? LLONG_MIN : LLONG_MAX;
    }
    return neg ? -(long long)acc : (long long)acc;
}
