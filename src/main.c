#include "codegen.h"
#include "lexer.h"
#include "parser.h"
#include "wat_builder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return NULL; }
    char *buf = malloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    if (got != (size_t)n) {
        fprintf(stderr, "%s: short read (%zu of %ld bytes)\n", path, got, n);
        free(buf);
        fclose(f);
        return NULL;
    }
    buf[n] = '\0';
    fclose(f);
    return buf;
}

static void usage(const char *prog) {
    fprintf(stderr, "usage: %s <input.lua> -o <output.wat>\n", prog);
}

int main(int argc, char **argv) {
    const char *in = NULL;
    const char *out = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) { out = argv[++i]; }
        else if (!in) { in = argv[i]; }
        else { usage(argv[0]); return 2; }
    }
    if (!in || !out) { usage(argv[0]); return 2; }

    char *src = read_file(in);
    if (!src) return 1;

    TokenList toks = lex(src);
    if (!toks.ok) {
        fprintf(stderr, "lex error: %s\n", toks.err);
        return 1;
    }

    NodePool pool;
    node_pool_init(&pool);
    ParseResult pr = parse(&toks, &pool);
    if (!pr.ok) {
        fprintf(stderr, "parse error: %s\n", pr.error);
        return 1;
    }

    /* Derive Lua-style source name: basename of input, sans .lua suffix.
     * Used by error() for the "<src>:<line>: " prefix and by
     * debug.traceback. */
    const char *base = strrchr(in, '/');
    base = base ? base + 1 : in;
    char src_name[128];
    snprintf(src_name, sizeof(src_name), "%s", base);
    size_t sn_len = strlen(src_name);
    if (sn_len >= 4 && strcmp(src_name + sn_len - 4, ".lua") == 0) {
        src_name[sn_len - 4] = '\0';
    }

    WatBuilder w;
    wat_init(&w);
    char err[256] = {0};
    if (!codegen_module(&pr, src_name, &w, err, sizeof(err))) {
        fprintf(stderr, "%s\n", err);
        return 1;
    }

    FILE *of = fopen(out, "wb");
    if (!of) { perror(out); return 1; }
    fputs(wat_cstr(&w), of);
    fclose(of);

    wat_free(&w);
    parse_result_free(&pr);
    node_pool_free(&pool);
    tokenlist_free(&toks);
    free(src);
    return 0;
}
