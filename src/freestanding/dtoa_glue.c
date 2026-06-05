/* Configure and include the vendored David Gay dtoa.c for the wasm32 build.
 *
 * dtoa.c gives us two correctly-rounded primitives the compiler needs:
 *   - strtod  (decimal/hex string -> double): the lexer's number literals.
 *   - dtoa    (double -> decimal digits): codegen's "%.17g" float constants,
 *             via the formatter in fmt.c.
 *
 * Config:
 *   IEEE_8087  little-endian IEEE-754 (wasm is little-endian). Exactly one
 *              arithmetic model must be selected.
 *   Long int   be explicit that dtoa's 32-bit integer type is `int` (on
 *              wasm32 `long` is also 32-bit, but spell it out).
 * long long is available, so dtoa uses its 64-bit fast paths. MALLOC/REALLOC/
 * FREE default to our malloc/realloc/free (alloc.c); Set_errno defaults to
 * `errno = x` (errno.h / baselib.c). Hex-float parsing is left enabled so the
 * lexer can hand 0x1.8p3-style literals straight to strtod. */

#define IEEE_8087
#define Long int

/* Vendored verbatim from netlib (David M. Gay / Lucent, permissive license)
 * under third_party/dtoa/; its old-style C trips -Wall, so the build compiles
 * this TU with warnings suppressed. */
#include "../../third_party/dtoa/dtoa.c"
