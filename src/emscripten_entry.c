/* Browser-side entry point: compile a Lua source string to a WAT text
 * string. Only built when targeting emscripten. */
#ifdef __EMSCRIPTEN__

#include "codegen.h"
#include "lexer.h"
#include "parser.h"
#include "wat_builder.h"

#include <emscripten.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *make_err(const char *prefix, const char *msg) {
    size_t n = strlen(prefix) + strlen(msg) + 8;
    char *buf = malloc(n);
    snprintf(buf, n, "%s%s", prefix, msg);
    return buf;
}

EMSCRIPTEN_KEEPALIVE
char *lua2wasm_compile(const char *source) {
    TokenList toks = lex(source);
    if (!toks.ok) {
        char *e = make_err("ERROR(lex): ", toks.err);
        tokenlist_free(&toks);
        return e;
    }
    NodePool pool;
    node_pool_init(&pool);
    ParseResult pr = parse(&toks, &pool);
    if (!pr.ok) {
        char *e = make_err("ERROR(parse): ", pr.error);
        parse_result_free(&pr);
        node_pool_free(&pool);
        tokenlist_free(&toks);
        return e;
    }
    WatBuilder w;
    wat_init(&w);
    char errbuf[256] = {0};
    if (!codegen_module(&pr, &w, errbuf, sizeof(errbuf))) {
        char *e = make_err("ERROR(codegen): ", errbuf);
        wat_free(&w);
        parse_result_free(&pr);
        node_pool_free(&pool);
        tokenlist_free(&toks);
        return e;
    }
    /* Transfer ownership of the WAT buffer to the caller. */
    char *out = w.buf;
    w.buf = NULL;
    parse_result_free(&pr);
    node_pool_free(&pool);
    tokenlist_free(&toks);
    return out;
}

EMSCRIPTEN_KEEPALIVE
void lua2wasm_free(char *p) { free(p); }

#endif /* __EMSCRIPTEN__ */
