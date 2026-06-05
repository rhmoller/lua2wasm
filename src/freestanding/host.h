/* Host imports for the freestanding wasm build. The module has no syscalls;
 * the two things it cannot do for itself — abort the process and emit a
 * diagnostic line — are provided by the embedder as wasm imports in the
 * "env" module. The JS glue (runtime/lua2wasm-wasm.mjs) supplies both; a C
 * game-engine embedder wires them to its own panic/log. */
#ifndef LUA2WASM_FREESTANDING_HOST_H
#define LUA2WASM_FREESTANDING_HOST_H

__attribute__((import_module("env"), import_name("abort"))) void host_abort(void);

__attribute__((import_module("env"), import_name("log"))) void host_log(const char *ptr,
                                                                        int len);

#endif /* LUA2WASM_FREESTANDING_HOST_H */
