/* Browser-side entry points: compile a Lua source string to WAT text, and
 * assemble WAT to a binary wasm module. Only built when targeting emscripten. */
#ifdef __EMSCRIPTEN__

#include "codegen.h"
#include "lexer.h"
#include "parser.h"
#include "wat2wasm.h"
#include "wat_builder.h"
#include "xalloc.h"

#include <emscripten.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *make_err(const char *prefix, const char *msg) {
    size_t n = strlen(prefix) + strlen(msg) + 8;
    char *buf = xmalloc(n);
    snprintf(buf, n, "%s%s", prefix, msg);
    return buf;
}

/* Browser compile entry. Called once per keystroke from the playground,
 * so every allocation path must be either freed before return or handed
 * to the caller (the returned WAT string). Single-exit via goto keeps
 * the cleanup obviously paired with the setup, regardless of which stage
 * failed. */
EMSCRIPTEN_KEEPALIVE char *lua2wasm_compile_ex(const char *source, int tree_shake);

EMSCRIPTEN_KEEPALIVE
char *lua2wasm_compile(const char *source) {
    return lua2wasm_compile_ex(source, 0);
}

/* As above, with explicit options:
 *   tree_shake — when nonzero, prune unused builtin closures + _G entries
 *   so wasm-opt can DCE the function bodies. Off by default for the
 *   playground because `_G.foo` introspection breaks for builtins the
 *   program doesn't name. */
EMSCRIPTEN_KEEPALIVE
char *lua2wasm_compile_ex(const char *source, int tree_shake) {
    char *result = NULL;
    int have_pool = 0, have_parse = 0, have_wat = 0;
    NodePool pool;
    ParseResult pr = {0};
    WatBuilder w = {0};

    TokenList toks = lex(source);
    if (!toks.ok) {
        result = make_err("ERROR(lex): ", toks.err);
        goto cleanup;
    }

    node_pool_init(&pool);
    have_pool = 1;
    pr = parse(&toks, &pool);
    have_parse = 1;
    if (!pr.ok) {
        result = make_err("ERROR(parse): ", pr.error);
        goto cleanup;
    }

    wat_init(&w);
    have_wat = 1;
    char errbuf[256] = {0};
    /* Playground compiles the inline buffer with no filename; use "input".
     * Tree-shake is opt-in via the UI toggle (passed in tree_shake). */
    if (!codegen_module(&pr, "input", tree_shake, &w, errbuf, sizeof(errbuf))) {
        result = make_err("ERROR(codegen): ", errbuf);
        goto cleanup;
    }
    /* Hand the WAT buffer to the caller; clear the builder's ref so the
     * cleanup below (which is a no-op for the buf via NULL) doesn't take
     * it back. */
    result = w.buf;
    w.buf = NULL;

cleanup:
    if (have_wat) wat_free(&w);
    if (have_parse) parse_result_free(&pr);
    if (have_pool) node_pool_free(&pool);
    tokenlist_free(&toks);
    return result;
}

EMSCRIPTEN_KEEPALIVE
void lua2wasm_free(char *p) { free(p); }

/* Assemble a WAT string into a binary wasm module using the built-in
 * assembler (no Binaryen). On success returns a malloc'd byte buffer (free
 * with lua2wasm_free) and writes its length to *out_len. On failure returns
 * NULL, sets *out_len to 0, and writes a message into err (capacity errcap). */
EMSCRIPTEN_KEEPALIVE
uint8_t *lua2wasm_assemble(const char *wat, int *out_len, char *err, int errcap) {
    uint8_t *bytes = NULL;
    size_t n = 0;
    if (wat_assemble(wat, strlen(wat), 1 /* dce */, &bytes, &n, err, (size_t)errcap) != 0) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    if (out_len) *out_len = (int)n;
    return bytes;
}

#endif /* __EMSCRIPTEN__ */
