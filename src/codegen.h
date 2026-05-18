#ifndef LUA2WASM_CODEGEN_H
#define LUA2WASM_CODEGEN_H

#include "parser.h"
#include "wat_builder.h"

/* tree_shake: when nonzero, only emit globals / elem-declare / _G
 * registrations for builtins referenced by the AST. Lets wasm-opt
 * drop the function bodies that no longer have a ref.func keeping
 * them live. Costs: `_G.print` access fails if user code never names
 * `print`. Default off. */
int codegen_module(const ParseResult *pr, const char *src_name,
                   int tree_shake, WatBuilder *out,
                   char *errbuf, size_t errbuf_len);

#endif
