/* fileno(), fstat() and S_ISREG are POSIX, not ISO C; the build uses
 * strict -std=c23 (no GNU extensions), so request them explicitly. */
#define _POSIX_C_SOURCE 200809L

#include "codegen.h"
#include "lexer.h"
#include "parser.h"
#include "wat2wasm.h"
#include "wat_builder.h"
#include "xalloc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return NULL;
    }
    /* Reject anything that isn't a regular file up front — fopen("rb") on a
     * directory "succeeds" on many platforms, then fseek/fread misbehave. */
    struct stat st;
    if (fstat(fileno(f), &st) != 0) {
        perror(path);
        fclose(f);
        return NULL;
    }
    if (!S_ISREG(st.st_mode)) {
        fprintf(stderr, "%s: not a regular file\n", path);
        fclose(f);
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        perror(path);
        fclose(f);
        return NULL;
    }
    long n = ftell(f);
    if (n < 0) {
        perror(path);
        fclose(f);
        return NULL;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        perror(path);
        fclose(f);
        return NULL;
    }
    char *buf = xmalloc((size_t)n + 1);
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

/* Lua skips a leading line starting with '#' (shebang / first-line marker)
 * in any loaded chunk. Blank that line in place — keeping the newline so
 * line numbers stay accurate — because modules get wrapped and concatenated
 * before lexing, so the lexer's own start-of-input skip only ever sees the
 * first source's shebang, not a module's (or the entry's, when modules
 * precede it). */
static void strip_shebang(char *s) {
    if (s && s[0] == '#') {
        for (char *p = s; *p && *p != '\n'; p++) *p = ' ';
    }
}

static void usage(const char *prog) {
    fprintf(stderr,
            "usage: %s <main.lua> [-m <module.lua>]... -o <output.wat>\n"
            "  -m FILE  load FILE as a require()-able module, keyed by basename\n",
            prog);
}

/* Extract module name from a path: basename without .lua suffix.
 * Returns 0 on success, -1 if the basename didn't fit in `cap`
 * (truncation would mis-key require(), so the caller must error out). */
static int module_name_of(const char *path, char *out, size_t cap) {
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    int w = snprintf(out, cap, "%s", base);
    if (w < 0 || (size_t)w >= cap) return -1;
    size_t n = strlen(out);
    if (n >= 4 && strcmp(out + n - 4, ".lua") == 0) out[n - 4] = '\0';
    return 0;
}

#define MAX_MODULES 32

int main(int argc, char **argv) {
    const char *in = NULL;
    const char *out = NULL;
    const char *modules[MAX_MODULES];
    int n_modules = 0;
    int tree_shake = 0;
    int no_dce = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            out = argv[++i];
        } else if (strcmp(argv[i], "--tree-shake") == 0) {
            tree_shake = 1;
        } else if (strcmp(argv[i], "--no-dce") == 0) {
            no_dce = 1;
        } else if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) {
            if (n_modules >= MAX_MODULES) {
                fprintf(stderr, "too many -m modules (max %d)\n", MAX_MODULES);
                return 2;
            }
            modules[n_modules++] = argv[++i];
        } else if (!in) {
            in = argv[i];
        } else {
            usage(argv[0]);
            return 2;
        }
    }
    if (!in || !out) {
        usage(argv[0]);
        return 2;
    }

    char *entry_src = read_file(in);
    if (!entry_src) return 1;
    strip_shebang(entry_src);

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
        /* Use a growable WatBuilder rather than a hand-estimated buffer:
         * it grows exactly as needed and aborts (via xalloc) on OOM, so
         * there's no unchecked size estimate to get wrong. */
        WatBuilder cb;
        wat_init(&cb);
        char mod_names[MAX_MODULES][128];
        for (int i = 0; i < n_modules; i++) {
            char *ms = read_file(modules[i]);
            if (!ms) {
                wat_free(&cb);
                return 1;
            }
            strip_shebang(ms);
            if (module_name_of(modules[i], mod_names[i],
                               sizeof(mod_names[i])) != 0) {
                fprintf(stderr, "%s: module name too long (max %zu)\n",
                        modules[i], sizeof(mod_names[i]) - 1);
                free(ms);
                wat_free(&cb);
                return 1;
            }
            wat_appendf(&cb, "package.preload[\"%s\"]=function()\n",
                        mod_names[i]);
            wat_append(&cb, ms);
            wat_append(&cb, "\nend\n");
            free(ms);
        }
        wat_append(&cb, entry_src);
        /* Hand off the builder's buffer as the owned source string. */
        combined = cb.buf;
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
    int sn_w = snprintf(src_name, sizeof(src_name), "%s", base);
    if (sn_w < 0 || (size_t)sn_w >= sizeof(src_name)) {
        fprintf(stderr, "%s: source name too long (max %zu)\n",
                in, sizeof(src_name) - 1);
        return 1;
    }
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

    /* Emit a binary module when the output ends in .wasm, otherwise WAT text. */
    const char *wat = wat_cstr(&w);
    size_t out_len = strlen(out);
    int emit_wasm = out_len >= 5 && strcmp(out + out_len - 5, ".wasm") == 0;
    if (emit_wasm) {
        uint8_t *bytes = NULL;
        size_t n = 0;
        char asm_err[512] = {0};
        if (wat_assemble(wat, strlen(wat), !no_dce, &bytes, &n, asm_err, sizeof asm_err) != 0) {
            fprintf(stderr, "%s\n", asm_err);
            return 1;
        }
        FILE *of = fopen(out, "wb");
        if (!of) {
            perror(out);
            free(bytes);
            return 1;
        }
        size_t wrote = fwrite(bytes, 1, n, of);
        fclose(of);
        free(bytes);
        if (wrote != n) {
            fprintf(stderr, "%s: short write\n", out);
            return 1;
        }
    } else {
        FILE *of = fopen(out, "wb");
        if (!of) {
            perror(out);
            return 1;
        }
        fputs(wat, of);
        fclose(of);
    }

    wat_free(&w);
    parse_result_free(&pr);
    node_pool_free(&pool);
    tokenlist_free(&toks);
    free(src);
    return 0;
}
