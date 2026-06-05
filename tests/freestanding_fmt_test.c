/* Differential test for the freestanding number<->string routines.
 *
 * The wasm build replaces the host libc with src/freestanding/. Its two
 * correctness-critical pieces are the float formatter (fmt.c, used by codegen
 * for "%.17g" constants) and strtod (vendored dtoa.c, used by the lexer). Both
 * must agree with the reference (glibc) or WAT goldens drift and parsed
 * literals round wrong. This compiles those exact sources natively under
 * aliases (so they don't collide with libc) and diffs them against glibc over
 * a large corpus: special values, exhaustive-ish small grids, and a big random
 * sweep of raw bit patterns. Any mismatch fails the build.
 *
 * Aliases (set via -D on the freestanding TUs in CMake):
 *   strtod   -> dg_strtod      (dtoa.c's strtod)
 *   l2w_vsnprintf              (fmt.c core, always exported)
 */

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern double dg_strtod(const char *s, char **end);
extern int l2w_vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap);

static int l2w_snprintf(char *buf, size_t cap, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = l2w_vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    return r;
}

static int g_fail;
static int g_checked;

/* Compare our formatting of `x` with `fmt` against glibc. */
static void check_fmt(const char *fmt, double x) {
    char ref[512], got[512];
    snprintf(ref, sizeof ref, fmt, x);
    l2w_snprintf(got, sizeof got, fmt, x);
    g_checked++;
    if (strcmp(ref, got) != 0) {
        if (g_fail < 25)
            fprintf(stderr, "FMT  %-8s ref=%-26s got=%-26s  (bits=%016llx)\n", fmt, ref, got,
                    (unsigned long long)*(uint64_t *)&x);
        g_fail++;
    }
}

/* Round-trip: format x with %.17g (glibc), parse the text with both libc
 * strtod and dg_strtod; the resulting doubles must be bit-identical. */
static void check_strtod(double x) {
    char s[64];
    snprintf(s, sizeof s, "%.17g", x);
    double a = strtod(s, NULL);
    double b = dg_strtod(s, NULL);
    g_checked++;
    if (memcmp(&a, &b, sizeof a) != 0) {
        if (g_fail < 25)
            fprintf(stderr, "STRTOD \"%s\": libc=%.17g dg=%.17g\n", s, a, b);
        g_fail++;
    }
}

/* Parse an arbitrary decimal/hex string with both and compare bits. */
static void check_parse(const char *s) {
    double a = strtod(s, NULL);
    double b = dg_strtod(s, NULL);
    g_checked++;
    if (memcmp(&a, &b, sizeof a) != 0) {
        if (g_fail < 25)
            fprintf(stderr, "PARSE \"%s\": libc=%.17g dg=%.17g\n", s, a, b);
        g_fail++;
    }
}

static void all_fmts(double x) {
    check_fmt("%.17g", x);
    check_fmt("%.15g", x);
    check_fmt("%g", x);
    check_fmt("%.0g", x);
    check_fmt("%.1g", x);
    check_fmt("%e", x);
    check_fmt("%.10e", x);
    check_fmt("%.0e", x);
    check_fmt("%f", x);
    check_fmt("%.3f", x);
    check_strtod(x);
}

int main(void) {
    static const double special[] = {
        0.0,    -0.0,        1.0,        -1.0,    0.1,    0.2,        0.3,
        0.5,    1.5,         2.0,        10.0,    100.0,  1e6,        1e21,
        1e-21,  123456789.123456789,     3.141592653589793,          2.718281828459045,
        1e308,  1e-308,      2.2250738585072014e-308 /*DBL_MIN*/,    4.9e-324 /*denorm*/,
        1.7976931348623157e308 /*DBL_MAX*/, 9007199254740993.0, 0.30000000000000004,
        1.0 / 3.0, 2.0 / 3.0, 12345.6789, 9.999999999999999e22, 8.3e26, 6.3876e-16,
    };
    for (size_t i = 0; i < sizeof special / sizeof special[0]; i++) all_fmts(special[i]);

    /* inf / nan formatting (glibc prints inf/nan/INF/NAN). */
    check_fmt("%g", INFINITY);
    check_fmt("%G", INFINITY);
    check_fmt("%e", -INFINITY);
    check_fmt("%f", INFINITY);
    check_fmt("%g", NAN);
    check_fmt("%+g", 1.5);
    check_fmt("% g", 1.5);
    check_fmt("%+.3e", -2.5);
    check_fmt("%10.2f", 3.14159);
    check_fmt("%-10.2f", 3.14159);
    check_fmt("%010.2f", 3.14159);
    check_fmt("%#.0f", 5.0);
    check_fmt("%#g", 100.0);

    /* small integer/fraction grid */
    for (int i = -50; i <= 50; i++) {
        all_fmts((double)i);
        all_fmts(i / 7.0);
        all_fmts(i * 1e-3);
        all_fmts(i * 1e3 + 0.5);
    }

    /* powers of ten and nearby */
    for (int e = -30; e <= 30; e++) {
        double p = pow(10.0, e);
        all_fmts(p);
        all_fmts(p * 1.234567890123);
        all_fmts(p * 9.999999999999);
    }

    /* large random sweep of raw bit patterns */
    srand(12345);
    long N = 200000;
    for (long i = 0; i < N; i++) {
        uint64_t bits = ((uint64_t)(uint32_t)rand() << 40) ^ ((uint64_t)(uint32_t)rand() << 11) ^
                        (uint64_t)(uint32_t)rand();
        double x;
        memcpy(&x, &bits, sizeof x);
        if (isnan(x) || isinf(x)) continue; /* %f/%e of these differ only trivially; skip */
        check_fmt("%.17g", x);
        check_fmt("%g", x);
        check_strtod(x);
    }

    /* explicit parse cases incl. hex floats and edge whitespace/exponents */
    const char *parses[] = {
        "0", "  3.14", "-0.0", "1e10", "1E-10", "0x1.8p3", "0x1p-1", "1.7976931348623159e308",
        "2.2250738585072011e-308", "9.999999999999999e22", "8.3e26", "6.3876e-16", "inf", "nan",
        ".5", "5.", "123456789012345678901234567890", "1e-400", "1e400",
    };
    for (size_t i = 0; i < sizeof parses / sizeof parses[0]; i++) check_parse(parses[i]);

    fprintf(stderr, "freestanding_fmt_test: %d checks, %d failures\n", g_checked, g_fail);
    return g_fail ? 1 : 0;
}
