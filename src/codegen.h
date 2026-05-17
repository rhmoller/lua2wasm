#ifndef LUA2WASM_CODEGEN_H
#define LUA2WASM_CODEGEN_H

#include "parser.h"
#include "wat_builder.h"

/* Emits a complete WAT module to `out` for the given program.
 * Returns 1 on success, 0 on failure (writes error to errbuf). */
int codegen_module(const Program *prog, WatBuilder *out, char *errbuf, size_t errbuf_len);

#endif
