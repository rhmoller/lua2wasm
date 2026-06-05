/* Freestanding <math.h> — only what the vendored dtoa.c references. dtoa
 * deliberately avoids transcendentals in its hot paths (it hardcodes the
 * log10/log2 constants), so the only real calls are floor/ceil, which map
 * directly to the wasm f64.floor / f64.ceil opcodes. log/log10 are declared
 * for completeness but are not expected to be referenced; if the link ever
 * pulls them in, that is a signal to revisit. */
#ifndef _MATH_H
#define _MATH_H

#define floor(x) __builtin_floor(x)
#define ceil(x) __builtin_ceil(x)

double log(double x);
double log10(double x);

#endif /* _MATH_H */
