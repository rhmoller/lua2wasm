#ifndef LUA2WASM_CODEGEN_H
#define LUA2WASM_CODEGEN_H

#include "parser.h"
#include "wat_builder.h"

/* tree_shake: when nonzero, only emit globals / elem-declare / _G
 * registrations for builtins referenced by the AST. Lets wasm-opt
 * drop the function bodies that no longer have a ref.func keeping
 * them live. Costs: `_G.print` access fails if user code never names
 * `print`. Default off.
 *
 * opt: optimization level. 0 (-O0) is the boxed fallback — every Lua value
 * is a host-GC object and arithmetic goes through generic dispatch. >=1 (the
 * default) enables numeric/call specialization: int/float slot unboxing,
 * typed direct-call entries, and comparison specialization. Behaviour is
 * identical across levels; only the emitted code shape and speed differ. */
int codegen_module(const ParseResult *pr, const char *src_name,
                   int tree_shake, int opt, WatBuilder *out,
                   char *errbuf, size_t errbuf_len);

#endif
