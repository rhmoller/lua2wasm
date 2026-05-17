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
    char *buf = malloc((size_t)n + 1);
    fread(buf, 1, (size_t)n, f);
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

    WatBuilder w;
    wat_init(&w);
    char err[256] = {0};
    if (!codegen_module(&pr, &w, err, sizeof(err))) {
        fprintf(stderr, "%s\n", err);
        return 1;
    }

    FILE *of = fopen(out, "wb");
    if (!of) { perror(out); return 1; }
    fputs(wat_cstr(&w), of);
    fclose(of);

    wat_free(&w);
    node_pool_free(&pool);
    tokenlist_free(&toks);
    free(src);
    return 0;
}
