/* Freestanding <errno.h>. The lexer clears errno before strtod and checks
 * for ERANGE; the vendored dtoa.c sets errno = ERANGE on overflow. A single
 * global (the module is single-threaded) is all we need. errno lives in
 * baselib.c. ERANGE's numeric value is arbitrary here — only == comparisons
 * against this macro matter. */
#ifndef _ERRNO_H
#define _ERRNO_H

extern int errno;

#define ERANGE 34
#define EDOM 33

#endif /* _ERRNO_H */
