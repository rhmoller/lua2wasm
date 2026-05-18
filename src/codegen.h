#ifndef LUA2WASM_CODEGEN_H
#define LUA2WASM_CODEGEN_H

#include "parser.h"
#include "wat_builder.h"

int codegen_module(const ParseResult *pr, const char *src_name,
                   WatBuilder *out, char *errbuf, size_t errbuf_len);

#endif
