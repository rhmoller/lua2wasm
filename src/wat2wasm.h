#ifndef WAT2WASM_H
#define WAT2WASM_H

#include <stddef.h>
#include <stdint.h>

/* wat2wasm — a small, self-contained WebAssembly text → binary assembler.
 *
 * Scope: the subset of the WAT format that lua2wasm emits (its codegen output
 * plus the hand-written runtime prelude) — WasmGC, typed function references,
 * and exception handling. It is NOT a general-purpose WAT parser: constructs
 * the compiler never produces (linear memory, tables, br_table, inline import
 * shorthands on funcs, etc.) are out of scope and reported as errors.
 *
 * The library depends only on the C standard library, so it can be linked
 * standalone (a `wat2wasm` CLI) or embedded in the compiler.
 */

/* Assemble `wat` (a NUL-terminated module in text format; `wat_len` is its
 * length, excluding the terminator) into a binary wasm module.
 *
 * When `dce` is non-zero, functions not reachable from the module's exports or
 * global initializers (following call / ref.func edges) are dropped — a
 * behavior-preserving size optimization.
 *
 * On success: returns 0, sets *out_bytes to a heap buffer (caller frees with
 * free()) and *out_len to its length.
 * On failure: returns non-zero and writes a diagnostic into `err`
 * (NUL-terminated, truncated to errcap); the out-params are untouched. */
int wat_assemble(const char *wat, size_t wat_len, int dce, uint8_t **out_bytes,
                 size_t *out_len, char *err, size_t errcap);

#endif
