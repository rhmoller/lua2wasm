/* wat2wasm CLI — assemble a .wat file into a .wasm binary.
 *
 * Usage: wat2wasm [flags...] -o <out.wasm> <in.wat>
 *
 * Unknown flags are accepted and ignored, so this is a drop-in replacement
 * for `wasm-as --all-features --disable-custom-descriptors -o out in` in the
 * build and test scripts. */

#define _POSIX_C_SOURCE 200809L

#include "wat2wasm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return NULL;
    }
    struct stat st;
    if (fstat(fileno(f), &st) != 0 || !S_ISREG(st.st_mode)) {
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
    if (n < 0 || fseek(f, 0, SEEK_SET) != 0) {
        perror(path);
        fclose(f);
        return NULL;
    }
    char *buf = malloc((size_t)n + 1);
    if (!buf) {
        fprintf(stderr, "%s: out of memory\n", path);
        fclose(f);
        return NULL;
    }
    size_t got = fread(buf, 1, (size_t)n, f);
    if (got != (size_t)n) {
        fprintf(stderr, "%s: short read\n", path);
        free(buf);
        fclose(f);
        return NULL;
    }
    buf[n] = '\0';
    *out_len = (size_t)n;
    fclose(f);
    return buf;
}

static void usage(const char *prog) {
    fprintf(stderr, "usage: %s [flags...] -o <out.wasm> <in.wat>\n", prog);
}

int main(int argc, char **argv) {
    const char *in = NULL;
    const char *out = NULL;
    int dce = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            out = argv[++i];
        } else if (strcmp(argv[i], "--dce") == 0) {
            dce = 1; /* drop functions unreachable from exports/globals */
        } else if (argv[i][0] == '-') {
            /* Ignore wasm-as-style flags (--all-features, etc.). */
            continue;
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

    size_t wat_len = 0;
    char *wat = read_file(in, &wat_len);
    if (!wat) return 1;

    uint8_t *bytes = NULL;
    size_t len = 0;
    char err[512] = {0};
    if (wat_assemble(wat, wat_len, dce, &bytes, &len, err, sizeof err) != 0) {
        fprintf(stderr, "%s: %s\n", in, err);
        free(wat);
        return 1;
    }
    free(wat);

    FILE *of = fopen(out, "wb");
    if (!of) {
        perror(out);
        free(bytes);
        return 1;
    }
    if (fwrite(bytes, 1, len, of) != len) {
        perror(out);
        fclose(of);
        free(bytes);
        return 1;
    }
    fclose(of);
    free(bytes);
    return 0;
}
