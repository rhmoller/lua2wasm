/* Formatted output for the freestanding build: snprintf / vsnprintf, plus a
 * fprintf that ignores its stream and routes the line to the host `log`
 * import (the compiler only ever fprintf's diagnostics to stderr).
 *
 * Integer/string/char conversions are handled here directly; floating point
 * (e/f/g and their uppercase forms) is delegated to the vendored, correctly
 * rounded David Gay dtoa() so that "%.17g" — the only float conversion codegen
 * emits — matches the reference (glibc) byte-for-byte, keeping WAT goldens
 * stable. The core is exposed as l2w_vsnprintf so the native differential test
 * can exercise it without colliding with the host libc's symbols. */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include "host.h"
#include "stdio.h"
#include "string.h"

/* David Gay dtoa() / freedtoa() from the vendored dtoa.c. */
extern char *dtoa(double dd, int mode, int ndigits, int *decpt, int *sign, char **rve);
extern void freedtoa(char *s);

/* %g strips trailing zeros, but only in the fractional part — integer-position
 * zeros are significant (they set the magnitude). Strip back to just after the
 * decimal point, then drop a now-bare point. No-op when there is no point.
 * Returns the new end pointer. */
static char *strip_frac_zeros(char *start, char *end) {
    char *dot = NULL;
    for (char *q = start; q < end; q++) {
        if (*q == '.') {
            dot = q;
            break;
        }
    }
    if (!dot) return end;
    while (end > dot + 1 && end[-1] == '0') end--;
    if (end == dot + 1) end--; /* remove the lone '.' */
    return end;
}

/* ---- bounded output sink --------------------------------------------- *
 * Tracks the full would-be length (n) even past the buffer, so the return
 * value matches C99 snprintf even on truncation. */
struct out {
    char *buf;
    size_t cap; /* usable bytes excluding the final NUL */
    size_t n;   /* characters that would have been written */
};

static void put(struct out *o, char c) {
    if (o->n < o->cap) o->buf[o->n] = c;
    o->n++;
}

static void put_mem(struct out *o, const char *s, size_t len) {
    for (size_t i = 0; i < len; i++) put(o, s[i]);
}

static void put_pad(struct out *o, char c, int count) {
    for (int i = 0; i < count; i++) put(o, c);
}

/* ---- format flags ----------------------------------------------------- */
#define F_MINUS 1u
#define F_PLUS  2u
#define F_SPACE 4u
#define F_HASH  8u
#define F_ZERO  16u

enum length { LEN_NONE,
              LEN_hh,
              LEN_h,
              LEN_l,
              LEN_ll,
              LEN_j,
              LEN_z,
              LEN_t,
              LEN_L };

/* Emit `body` (length blen) preceded by `prefix` (e.g. "-", "0x"), honoring
 * field width, left-justify, and zero-pad. With zero-padding the prefix stays
 * left of the zeros. */
static void emit_field(struct out *o, const char *prefix, int plen, const char *body, int blen,
                       int width, unsigned flags) {
    int total = plen + blen;
    int pad = width > total ? width - total : 0;

    if (flags & F_MINUS) {
        put_mem(o, prefix, (size_t)plen);
        put_mem(o, body, (size_t)blen);
        put_pad(o, ' ', pad);
    } else if (flags & F_ZERO) {
        put_mem(o, prefix, (size_t)plen);
        put_pad(o, '0', pad);
        put_mem(o, body, (size_t)blen);
    } else {
        put_pad(o, ' ', pad);
        put_mem(o, prefix, (size_t)plen);
        put_mem(o, body, (size_t)blen);
    }
}

/* Unsigned -> ASCII in the given base. Writes into the END of buf and returns
 * a pointer to the first digit (so callers can size without copying). */
static char *u_to_str(uintmax_t v, unsigned base, int upper, char *bufend) {
    static const char lo[] = "0123456789abcdef";
    static const char up[] = "0123456789ABCDEF";
    const char *digits = upper ? up : lo;
    char *p = bufend;
    *--p = '\0';
    if (v == 0) *--p = '0';
    while (v) {
        *--p = digits[v % base];
        v /= base;
    }
    return p;
}

/* ---- floating point via dtoa ----------------------------------------- *
 * Renders the unsigned magnitude of a finite double in the requested style
 * into `tmp` (returns its length). decpt/digits come from dtoa; we place the
 * decimal point and pad/strip zeros per the C conversion rules. */
static int render_float(char *tmp, double mag, char conv, int prec, unsigned flags) {
    int lower = (conv >= 'a');
    char c = lower ? conv : (char)(conv + 32); /* normalize to e/f/g */
    int strip = 0;                             /* %g strips trailing zeros */
    int mode, ndig;

    if (c == 'g') {
        int P = prec <= 0 ? (prec == 0 ? 1 : 6) : prec;
        mode = 2;
        ndig = P;
        strip = !(flags & F_HASH);
    } else if (c == 'e') {
        if (prec < 0) prec = 6;
        mode = 2;
        ndig = prec + 1;
    } else { /* 'f' */
        if (prec < 0) prec = 6;
        mode = 3;
        ndig = prec;
    }

    int decpt = 0, sign = 0;
    char *ds = dtoa(mag, mode, ndig, &decpt, &sign, NULL);
    int nd = (int)strlen(ds);

    /* dtoa returns decpt==9999 for inf/nan, but those are handled by the
     * caller before we get here. decpt is the count of digits to the left of
     * the point (value = 0.<ds> x 10^decpt). */
    char *t = tmp;

    if (c == 'g') {
        int X = decpt - 1; /* exponent if written in scientific form */
        int P = prec <= 0 ? (prec == 0 ? 1 : 6) : prec;
        if (X < -4 || X >= P) {
            c = 'e';
            prec = P - 1;
        } else {
            c = 'f';
            prec = P - 1 - X;
        }
    }

    if (c == 'e') {
        int exp = decpt - 1;
        if (nd == 0) { /* value is zero */
            *t++ = '0';
            exp = 0;
        } else {
            *t++ = ds[0];
        }
        int frac = prec; /* digits after the point */
        if (frac > 0 || (flags & F_HASH)) *t++ = '.';
        for (int i = 0; i < frac; i++) *t++ = (i + 1 < nd) ? ds[i + 1] : '0';
        if (strip) t = strip_frac_zeros(tmp, t); /* %g: drop fractional zeros */
        *t++ = lower ? 'e' : 'E';
        if (exp < 0) {
            *t++ = '-';
            exp = -exp;
        } else {
            *t++ = '+';
        }
        char eb[8];
        char *ep = u_to_str((uintmax_t)exp, 10, 0, eb + sizeof eb);
        int elen = (int)(eb + sizeof eb - 1 - ep);
        if (elen < 2) *t++ = '0'; /* exponent has at least two digits */
        for (; *ep; ep++) *t++ = *ep;
    } else { /* 'f' */
        if (decpt <= 0) {
            *t++ = '0';
        } else {
            for (int i = 0; i < decpt; i++) *t++ = (i < nd) ? ds[i] : '0';
        }
        int frac = prec;
        if (frac > 0 || (flags & F_HASH)) *t++ = '.';
        for (int i = 0; i < frac; i++) {
            int idx = decpt + i; /* index into ds for this fractional place */
            *t++ = (idx >= 0 && idx < nd) ? ds[idx] : '0';
        }
        if (strip) t = strip_frac_zeros(tmp, t);
    }

    freedtoa(ds);
    return (int)(t - tmp);
}

static void fmt_float(struct out *o, double v, char conv, int prec, unsigned flags, int width) {
    int upper = (conv < 'a');
    char sign = 0;
    if (__builtin_signbit(v)) {
        sign = '-';
        v = -v;
    } else if (flags & F_PLUS) {
        sign = '+';
    } else if (flags & F_SPACE) {
        sign = ' ';
    }
    char pfx[1];
    int plen = 0;
    if (sign) {
        pfx[0] = sign;
        plen = 1;
    }

    if (__builtin_isnan(v) || __builtin_isinf(v)) {
        const char *body = __builtin_isnan(v) ? (upper ? "NAN" : "nan") : (upper ? "INF" : "inf");
        /* zero-pad never applies to inf/nan */
        emit_field(o, pfx, plen, body, 3, width, flags & ~F_ZERO);
        return;
    }

    char tmp[1100];
    int len = render_float(tmp, v, conv, prec, flags);
    emit_field(o, pfx, plen, tmp, len, width, flags);
}

/* ---- core ------------------------------------------------------------- */
int l2w_vsnprintf(char *__restrict buf, size_t cap, const char *__restrict fmt, va_list ap) {
    struct out o = {buf, cap ? cap - 1 : 0, 0};

    for (const char *f = fmt; *f; f++) {
        if (*f != '%') {
            put(&o, *f);
            continue;
        }
        f++;

        unsigned flags = 0;
        for (;; f++) {
            if (*f == '-')
                flags |= F_MINUS;
            else if (*f == '+')
                flags |= F_PLUS;
            else if (*f == ' ')
                flags |= F_SPACE;
            else if (*f == '#')
                flags |= F_HASH;
            else if (*f == '0')
                flags |= F_ZERO;
            else
                break;
        }

        int width = 0;
        if (*f == '*') {
            width = va_arg(ap, int);
            if (width < 0) {
                flags |= F_MINUS;
                width = -width;
            }
            f++;
        } else {
            while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
        }

        int prec = -1;
        if (*f == '.') {
            f++;
            prec = 0;
            if (*f == '*') {
                prec = va_arg(ap, int);
                f++;
            } else {
                while (*f >= '0' && *f <= '9') prec = prec * 10 + (*f++ - '0');
            }
            if (prec < 0) prec = -1;
        }

        enum length len = LEN_NONE;
        switch (*f) {
        case 'h':
            if (f[1] == 'h') {
                len = LEN_hh;
                f += 2;
            } else {
                len = LEN_h;
                f++;
            }
            break;
        case 'l':
            if (f[1] == 'l') {
                len = LEN_ll;
                f += 2;
            } else {
                len = LEN_l;
                f++;
            }
            break;
        case 'j':
            len = LEN_j;
            f++;
            break;
        case 'z':
            len = LEN_z;
            f++;
            break;
        case 't':
            len = LEN_t;
            f++;
            break;
        case 'L':
            len = LEN_L;
            f++;
            break;
        default:
            break;
        }

        char conv = *f;
        switch (conv) {
        case '%':
            put(&o, '%');
            break;

        case 'c': {
            char ch = (char)va_arg(ap, int);
            emit_field(&o, "", 0, &ch, 1, width, flags & ~F_ZERO);
            break;
        }

        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            int slen = 0;
            while (s[slen] && (prec < 0 || slen < prec)) slen++;
            emit_field(&o, "", 0, s, slen, width, flags & ~F_ZERO);
            break;
        }

        case 'd':
        case 'i': {
            intmax_t v;
            switch (len) {
            case LEN_l: v = va_arg(ap, long); break;
            case LEN_ll: v = va_arg(ap, long long); break;
            case LEN_j: v = va_arg(ap, intmax_t); break;
            case LEN_z: v = (intmax_t)va_arg(ap, ptrdiff_t); break;
            case LEN_t: v = (intmax_t)va_arg(ap, ptrdiff_t); break;
            case LEN_hh: v = (signed char)va_arg(ap, int); break;
            case LEN_h: v = (short)va_arg(ap, int); break;
            default: v = va_arg(ap, int); break;
            }
            char nb[24];
            uintmax_t mag = v < 0 ? (uintmax_t)(-(v + 1)) + 1u : (uintmax_t)v;
            char *p = u_to_str(mag, 10, 0, nb + sizeof nb);
            const char *pfx = v < 0 ? "-" : (flags & F_PLUS) ? "+"
                                        : (flags & F_SPACE)  ? " "
                                                             : "";
            emit_field(&o, pfx, (int)strlen(pfx), p, (int)strlen(p), width, flags);
            break;
        }

        case 'u':
        case 'o':
        case 'x':
        case 'X': {
            uintmax_t v;
            switch (len) {
            case LEN_l: v = va_arg(ap, unsigned long); break;
            case LEN_ll: v = va_arg(ap, unsigned long long); break;
            case LEN_j: v = va_arg(ap, uintmax_t); break;
            case LEN_z: v = va_arg(ap, size_t); break;
            case LEN_t: v = (uintmax_t)va_arg(ap, ptrdiff_t); break;
            case LEN_hh: v = (unsigned char)va_arg(ap, unsigned); break;
            case LEN_h: v = (unsigned short)va_arg(ap, unsigned); break;
            default: v = va_arg(ap, unsigned); break;
            }
            unsigned base = (conv == 'o') ? 8 : (conv == 'u') ? 10
                                                              : 16;
            int upper = (conv == 'X');
            char nb[24];
            char *p = u_to_str(v, base, upper, nb + sizeof nb);
            const char *pfx = "";
            if ((flags & F_HASH) && v != 0) {
                if (conv == 'x')
                    pfx = "0x";
                else if (conv == 'X')
                    pfx = "0X";
            }
            emit_field(&o, pfx, (int)strlen(pfx), p, (int)strlen(p), width, flags);
            break;
        }

        case 'p': {
            uintptr_t v = (uintptr_t)va_arg(ap, void *);
            char nb[24];
            char *p = u_to_str(v, 16, 0, nb + sizeof nb);
            emit_field(&o, "0x", 2, p, (int)strlen(p), width, flags);
            break;
        }

        case 'e':
        case 'E':
        case 'f':
        case 'F':
        case 'g':
        case 'G': {
            double v = va_arg(ap, double);
            fmt_float(&o, v, conv, prec, flags, width);
            break;
        }

        case '\0':
            f--; /* trailing '%': stop cleanly on the loop's f++ */
            break;

        default:
            put(&o, '%');
            put(&o, conv);
            break;
        }
    }

    if (o.cap || o.buf) {
        size_t term = o.n < o.cap ? o.n : o.cap;
        if (buf && cap) o.buf[term] = '\0';
    }
    return (int)o.n;
}

#ifndef L2W_NATIVE_TEST

int vsnprintf(char *__restrict buf, size_t cap, const char *__restrict fmt, va_list ap) {
    return l2w_vsnprintf(buf, cap, fmt, ap);
}

int snprintf(char *__restrict buf, size_t cap, const char *__restrict fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = l2w_vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    return r;
}

/* The stream is ignored; the compiler only writes diagnostics to stderr, which
 * we forward to the host log import as a single line. */
FILE *stderr = (FILE *)0;
FILE *stdout = (FILE *)0;

int fprintf(FILE *stream, const char *__restrict fmt, ...) {
    (void)stream;
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    int r = l2w_vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    int len = r < (int)sizeof line ? r : (int)sizeof line - 1;
    host_log(line, len);
    return r;
}

#endif /* L2W_NATIVE_TEST */
