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
    fprintf(stderr,
        "usage: %s <main.lua> [-m <module.lua>]... -o <output.wat>\n"
        "  -m FILE  load FILE as a require()-able module, keyed by basename\n",
        prog);
}

/* Extract module name from a path: basename without .lua suffix. */
static void module_name_of(const char *path, char *out, size_t cap) {
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    snprintf(out, cap, "%s", base);
    size_t n = strlen(out);
    if (n >= 4 && strcmp(out + n - 4, ".lua") == 0) out[n - 4] = '\0';
}

#define MAX_MODULES 32

int main(int argc, char **argv) {
    const char *in = NULL;
    const char *out = NULL;
    const char *modules[MAX_MODULES];
    int n_modules = 0;
    int tree_shake = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) { out = argv[++i]; }
        else if (strcmp(argv[i], "--tree-shake") == 0) { tree_shake = 1; }
        else if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) {
            if (n_modules >= MAX_MODULES) {
                fprintf(stderr, "too many -m modules (max %d)\n", MAX_MODULES);
                return 2;
            }
            modules[n_modules++] = argv[++i];
        }
        else if (!in) { in = argv[i]; }
        else { usage(argv[0]); return 2; }
    }
    if (!in || !out) { usage(argv[0]); return 2; }

    char *entry_src = read_file(in);
    if (!entry_src) return 1;

    /* Build the combined source: prepend each module wrapped in
     *   package.preload["NAME"] = function()
     *     <module source>
     *   end
     * then append the entry source. require() at runtime walks this
     * table; see $builtin_require.
     *
     * Line numbers inside module sources shift by the preceding text —
     * a known limitation that error() prefixes inherit. */
    char *src = entry_src;
    char *combined = NULL;
    if (n_modules > 0) {
        size_t total = 0;
        char *mod_srcs[MAX_MODULES];
        char mod_names[MAX_MODULES][128];
        for (int i = 0; i < n_modules; i++) {
            mod_srcs[i] = read_file(modules[i]);
            if (!mod_srcs[i]) return 1;
            module_name_of(modules[i], mod_names[i], sizeof(mod_names[i]));
            /* approx: wrapper + name + content + end-newline */
            total += strlen(mod_srcs[i]) + strlen(mod_names[i]) + 64;
        }
        total += strlen(entry_src) + 1;
        combined = malloc(total);
        if (!combined) return 1;
        size_t off = 0;
        for (int i = 0; i < n_modules; i++) {
            int w = snprintf(combined + off, total - off,
                "package.preload[\"%s\"]=function()\n", mod_names[i]);
            off += (size_t)w;
            size_t ml = strlen(mod_srcs[i]);
            memcpy(combined + off, mod_srcs[i], ml);
            off += ml;
            w = snprintf(combined + off, total - off, "\nend\n");
            off += (size_t)w;
            free(mod_srcs[i]);
        }
        size_t el = strlen(entry_src);
        memcpy(combined + off, entry_src, el);
        off += el;
        combined[off] = '\0';
        free(entry_src);
        src = combined;
    }

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
    if (!codegen_module(&pr, src_name, tree_shake, &w, err, sizeof(err))) {
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
