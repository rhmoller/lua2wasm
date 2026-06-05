/* Browser/embedder entry points for the freestanding wasm build of the
 * compiler: compile a Lua source string to WAT text, assemble WAT to a binary
 * module, and report the DCE-dead symbols. These wrap the same core the native
 * CLI uses (lex -> parse -> codegen_module / wat_assemble); the only thing this
 * file adds is the wasm export surface.
 *
 * Built only for wasm32 (the native CLI is src/main.c). The module is plain
 * freestanding wasm — no Emscripten — so each function is exported by name via
 * the export_name attribute; the host marshals strings through the module's
 * linear memory (see runtime/lua2wasm-wasm.mjs), using the exported malloc/free
 * to allocate the source buffer. */

#include "codegen.h"
#include "lexer.h"
#include "parser.h"
#include "wat2wasm.h"
#include "wat_builder.h"
#include "xalloc.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WASM_EXPORT(name) __attribute__((export_name(name), used, visibility("default")))

static char *make_err(const char *prefix, const char *msg) {
    size_t n = strlen(prefix) + strlen(msg) + 8;
    char *buf = xmalloc(n);
    snprintf(buf, n, "%s%s", prefix, msg);
    return buf;
}

WASM_EXPORT("lua2wasm_compile_ex")
char *lua2wasm_compile_ex(const char *source, int tree_shake, int embed_api);

/* Browser compile entry. Called once per keystroke from the playground, so
 * every allocation path must be either freed before return or handed to the
 * caller (the returned WAT string). Single-exit via goto keeps the cleanup
 * obviously paired with the setup, regardless of which stage failed. */
WASM_EXPORT("lua2wasm_compile")
char *lua2wasm_compile(const char *source) { return lua2wasm_compile_ex(source, 0, 0); }

/* As above, with explicit options:
 *   tree_shake — when nonzero, *force* pruning of un-named builtin closures +
 *   _G entries even for programs that aren't globally closed (the CLI's
 *   --force-tree-shake). Codegen already tree-shakes closed programs
 *   automatically, so lua2wasm_compile (tree_shake = 0) is the right default;
 *   this entry exists for callers that want the unsafe force (it can make
 *   `_G.foo` lookups of un-named builtins return nil).
 *   embed_api — when nonzero, also export the host-call ABI (lua_call/
 *   lua_get_global/...) so an embedder can invoke Lua functions in the produced
 *   module from outside (forces the whole stdlib live; see codegen.h). */
WASM_EXPORT("lua2wasm_compile_ex")
char *lua2wasm_compile_ex(const char *source, int tree_shake, int embed_api) {
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
     * Tree-shake is opt-in via the UI toggle (passed in tree_shake).
     * Numeric/call specialization is always on (opt=1, the CLI default). */
    if (!codegen_module(&pr, "input", tree_shake, 1, embed_api, &w, errbuf, sizeof(errbuf))) {
        result = make_err("ERROR(codegen): ", errbuf);
        goto cleanup;
    }
    /* Hand the WAT buffer to the caller; clear the builder's ref so the cleanup
     * below (which is a no-op for the buf via NULL) doesn't take it back. */
    result = w.buf;
    w.buf = NULL;

cleanup:
    if (have_wat) wat_free(&w);
    if (have_parse) parse_result_free(&pr);
    if (have_pool) node_pool_free(&pool);
    tokenlist_free(&toks);
    return result;
}

WASM_EXPORT("lua2wasm_free")
void lua2wasm_free(char *p) { free(p); }

/* Assemble a WAT string into a binary wasm module using the built-in assembler.
 * On success returns a malloc'd byte buffer (free with lua2wasm_free) and writes
 * its length to *out_len. On failure returns NULL, sets *out_len to 0, and
 * writes a message into err (capacity errcap). */
WASM_EXPORT("lua2wasm_assemble")
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

/* Report which named functions/globals the DCE pass proves dead in `wat`, as a
 * newline-separated, NUL-terminated string (functions first, then globals). The
 * playground uses this to dim the regions DCE would drop in the WAT view.
 * Returns an empty string when nothing is dead, or NULL if `wat` can't be
 * assembled (caller skips dimming). Free the result with lua2wasm_free. */
WASM_EXPORT("lua2wasm_dce_dead_names")
char *lua2wasm_dce_dead_names(const char *wat) {
    char *names = NULL;
    char err[256];
    if (wat_dead_names(wat, strlen(wat), &names, err, sizeof err) != 0) return NULL;
    return names;
}
