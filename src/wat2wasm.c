/* wat2wasm — WebAssembly text → binary assembler. See wat2wasm.h for scope.
 *
 * Built up test-first, one WAT construct family at a time (see
 * tests/wat2wasm/run.mjs). This stage covers the minimal vertical slice:
 * (module) with (func)s — params/results/locals, folded numeric
 * instructions, local accessors, select/drop/return — encoded into the
 * type, function, export, and code sections.
 *
 * Design notes:
 *   - The reader produces a tree of SExpr nodes (children as a linked list)
 *     allocated from an arena, so the whole tree frees in one step.
 *   - Errors longjmp back to wat_assemble with a message; the arena and the
 *     output buffer are released there on every path.
 *   - Encoding is post-order: an instruction's folded operand children are
 *     emitted before its own opcode, which is exactly the binary stack order.
 */

#include "wat2wasm.h"

#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- allocation -------------------------------------------------------- */

static void *xreserve(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) abort();
    return p;
}

static void *xgrow(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) abort();
    return q;
}

/* --- byte buffer ------------------------------------------------------- */

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} Buf;

static void buf_init(Buf *b) {
    b->cap = 64;
    b->data = xreserve(b->cap);
    b->len = 0;
}

static void buf_free(Buf *b) {
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}

static void buf_reserve(Buf *b, size_t extra) {
    if (b->len + extra <= b->cap) return;
    while (b->len + extra > b->cap) b->cap *= 2;
    b->data = xgrow(b->data, b->cap);
}

static void buf_byte(Buf *b, uint8_t x) {
    buf_reserve(b, 1);
    b->data[b->len++] = x;
}

static void buf_bytes(Buf *b, const void *p, size_t n) {
    buf_reserve(b, n);
    memcpy(b->data + b->len, p, n);
    b->len += n;
}

static void buf_append(Buf *b, const Buf *src) { buf_bytes(b, src->data, src->len); }

static void buf_uleb(Buf *b, uint64_t v) {
    do {
        uint8_t byte = v & 0x7f;
        v >>= 7;
        if (v) byte |= 0x80;
        buf_byte(b, byte);
    } while (v);
}

static void buf_sleb(Buf *b, int64_t v) {
    int more = 1;
    while (more) {
        uint8_t byte = v & 0x7f;
        v >>= 7; /* arithmetic shift */
        if ((v == 0 && !(byte & 0x40)) || (v == -1 && (byte & 0x40)))
            more = 0;
        else
            byte |= 0x80;
        buf_byte(b, byte);
    }
}

static void buf_f32(Buf *b, float f) {
    uint32_t bits;
    memcpy(&bits, &f, 4);
    for (int i = 0; i < 4; i++) buf_byte(b, (bits >> (8 * i)) & 0xff);
}

static void buf_f64(Buf *b, double d) {
    uint64_t bits;
    memcpy(&bits, &d, 8);
    for (int i = 0; i < 8; i++) buf_byte(b, (uint8_t)(bits >> (8 * i)));
}

/* --- arena ------------------------------------------------------------- */

typedef struct ArenaBlk {
    struct ArenaBlk *next;
    size_t used, cap;
    char data[];
} ArenaBlk;

typedef struct {
    ArenaBlk *head;
} Arena;

#define ARENA_BLK (64 * 1024)

static void *arena_alloc(Arena *a, size_t n) {
    n = (n + 7) & ~(size_t)7; /* 8-byte align */
    if (!a->head || a->head->used + n > a->head->cap) {
        size_t cap = n > ARENA_BLK ? n : ARENA_BLK;
        ArenaBlk *blk = xreserve(sizeof(ArenaBlk) + cap);
        blk->next = a->head;
        blk->used = 0;
        blk->cap = cap;
        a->head = blk;
    }
    void *p = a->head->data + a->head->used;
    a->head->used += n;
    return p;
}

static void arena_free(Arena *a) {
    for (ArenaBlk *b = a->head; b;) {
        ArenaBlk *next = b->next;
        free(b);
        b = next;
    }
    a->head = NULL;
}

/* --- s-expression tree ------------------------------------------------- */

typedef struct SExpr {
    int is_list;
    /* atom */
    const char *atom; /* NUL-terminated; for strings, the decoded bytes */
    size_t atom_len;  /* decoded length (atoms/strings may embed NUL) */
    int is_string;
    size_t src_pos; /* byte offset of this token/list in the source */
    /* list: children as a singly linked list */
    struct SExpr *first, *last;
    size_t n_kids;
    /* sibling link within the parent's child list */
    struct SExpr *next;
} SExpr;

/* --- declared types ---------------------------------------------------- */

/* One declared (type ...) entry. `comptype` is the (func..)/(struct..)/
 * (array..) node; sub-typing and (for structs) field names are recorded so
 * the encoder and instruction stream can resolve them by name. */
typedef struct DeclType {
    const char *name;
    const SExpr *comptype;
    int has_sub, is_final;
    const SExpr *supers[8];
    size_t n_supers;
    const char **field_names; /* struct field names (NULL entries if anon) */
    size_t n_fields;
} DeclType;

/* --- assembler context ------------------------------------------------- */

struct SigTable;

typedef struct {
    jmp_buf jb;
    char *err;
    size_t errcap;
    Arena arena;
    /* lexer cursor */
    const char *src;
    size_t len, pos;
    /* module-level name -> index tables, populated before body encoding.
     * Entry i holds the $name for index i (NULL if anonymous). */
    const char **func_names; /* imported funcs first, then defined */
    size_t n_func_names;
    const char **global_names;
    size_t n_global_names;
    const char **tag_names;
    size_t n_tag_names;
    const char **data_names;
    size_t n_data_names;
    /* declared types (index -> def) for $name / field resolution. Synthesized
     * func types are appended after these, starting at n_decl_types. */
    const DeclType *decls;
    size_t n_decl_types;
    struct SigTable *sigs; /* synthesized func/block signature types */
    /* dead-code elimination: when non-NULL, map an old function/global index to
     * its index in the pruned output. Applied wherever such an index is
     * emitted (calls, ref.func, global.get/set, exports, elem). */
    const uint32_t *func_remap;
    const uint32_t *global_remap;
    /* DCE over the synthesized signature table: maps an old synthesized-sig
     * slot to its index among the survivors (0xffffffff for dropped sigs,
     * which live code never references). NULL when DCE is off. */
    const uint32_t *sig_remap;
} Ctx;

/* Apply the DCE remaps to a function / global index, if active. */
static uint32_t map_func(Ctx *c, uint32_t old) {
    return c->func_remap ? c->func_remap[old] : old;
}
static uint32_t map_global(Ctx *c, uint32_t old) {
    return c->global_remap ? c->global_remap[old] : old;
}
/* Apply the synthesized-signature remap to a *type* index. Declared types keep
 * their slots (indices below n_decl_types); only the appended func signatures
 * are compacted, so they shift by the remap. */
static uint32_t map_typeidx(Ctx *c, uint32_t t) {
    if (!c->sig_remap || t < c->n_decl_types) return t;
    return (uint32_t)c->n_decl_types + c->sig_remap[t - c->n_decl_types];
}

static void fail(Ctx *c, const char *fmt, ...) {
    if (c->err && c->errcap) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(c->err, c->errcap, fmt, ap);
        va_end(ap);
    }
    longjmp(c->jb, 1);
}

/* 1-based source line of a byte offset, for diagnostics. */
static size_t line_of(Ctx *c, size_t pos) {
    size_t line = 1;
    for (size_t i = 0; i < pos && i < c->len; i++)
        if (c->src[i] == '\n') line++;
    return line;
}

/* --- lexer + reader ---------------------------------------------------- */

static int is_space(int ch) { return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'; }

/* A token-character is anything that isn't whitespace, a paren, a quote, or
 * a comment introducer. */
static int is_atom_char(int ch) {
    return ch && !is_space(ch) && ch != '(' && ch != ')' && ch != '"' && ch != ';';
}

/* Skip whitespace and comments (;; line, (; ... ;) nestable block). */
static void skip_trivia(Ctx *c) {
    for (;;) {
        while (c->pos < c->len && is_space((unsigned char)c->src[c->pos])) c->pos++;
        if (c->pos + 1 < c->len && c->src[c->pos] == ';' && c->src[c->pos + 1] == ';') {
            c->pos += 2;
            while (c->pos < c->len && c->src[c->pos] != '\n') c->pos++;
            continue;
        }
        if (c->pos + 1 < c->len && c->src[c->pos] == '(' && c->src[c->pos + 1] == ';') {
            int depth = 1;
            c->pos += 2;
            while (c->pos < c->len && depth > 0) {
                if (c->pos + 1 < c->len && c->src[c->pos] == '(' && c->src[c->pos + 1] == ';') {
                    depth++;
                    c->pos += 2;
                } else if (c->pos + 1 < c->len && c->src[c->pos] == ';' &&
                           c->src[c->pos + 1] == ')') {
                    depth--;
                    c->pos += 2;
                } else {
                    c->pos++;
                }
            }
            continue;
        }
        return;
    }
}

static int hexval(int ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

/* Encode a Unicode code point as UTF-8 into buf (4 bytes max); return count. */
static size_t utf8_encode(uint32_t cp, uint8_t out[4]) {
    if (cp < 0x80) {
        out[0] = (uint8_t)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = 0xC0 | (cp >> 6);
        out[1] = 0x80 | (cp & 0x3F);
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = 0xE0 | (cp >> 12);
        out[1] = 0x80 | ((cp >> 6) & 0x3F);
        out[2] = 0x80 | (cp & 0x3F);
        return 3;
    }
    out[0] = 0xF0 | (cp >> 18);
    out[1] = 0x80 | ((cp >> 12) & 0x3F);
    out[2] = 0x80 | ((cp >> 6) & 0x3F);
    out[3] = 0x80 | (cp & 0x3F);
    return 4;
}

/* Read a "..." string starting at the opening quote; decode escapes into the
 * arena. Sets *out_len. WAT escapes: \t \n \r \" \' \\ \HH (hex byte)
 * \u{XXXX} (code point). */
static const char *read_string(Ctx *c, size_t *out_len) {
    c->pos++; /* opening quote */
    /* Decode into a temporary buffer, then copy into the arena. */
    Buf tmp;
    buf_init(&tmp);
    while (c->pos < c->len && c->src[c->pos] != '"') {
        char ch = c->src[c->pos];
        if (ch != '\\') {
            buf_byte(&tmp, (uint8_t)ch);
            c->pos++;
            continue;
        }
        c->pos++;
        if (c->pos >= c->len) break;
        char e = c->src[c->pos];
        switch (e) {
        case 't':
            buf_byte(&tmp, '\t');
            c->pos++;
            break;
        case 'n':
            buf_byte(&tmp, '\n');
            c->pos++;
            break;
        case 'r':
            buf_byte(&tmp, '\r');
            c->pos++;
            break;
        case '"':
            buf_byte(&tmp, '"');
            c->pos++;
            break;
        case '\'':
            buf_byte(&tmp, '\'');
            c->pos++;
            break;
        case '\\':
            buf_byte(&tmp, '\\');
            c->pos++;
            break;
        case 'u': {
            c->pos++;
            if (c->pos >= c->len || c->src[c->pos] != '{')
                fail(c, "bad \\u escape in string");
            c->pos++;
            uint32_t cp = 0;
            int any = 0;
            while (c->pos < c->len && c->src[c->pos] != '}') {
                int hv = hexval((unsigned char)c->src[c->pos]);
                if (hv < 0) fail(c, "bad hex in \\u{} escape");
                cp = cp * 16 + (uint32_t)hv;
                any = 1;
                c->pos++;
            }
            if (!any || c->pos >= c->len) fail(c, "unterminated \\u{} escape");
            c->pos++; /* closing } */
            uint8_t u[4];
            size_t un = utf8_encode(cp, u);
            buf_bytes(&tmp, u, un);
            break;
        }
        default: {
            int hi = hexval((unsigned char)e);
            if (hi < 0) fail(c, "bad escape '\\%c' in string", e);
            c->pos++;
            if (c->pos >= c->len) fail(c, "truncated hex escape");
            int lo = hexval((unsigned char)c->src[c->pos]);
            if (lo < 0) fail(c, "bad hex escape in string");
            c->pos++;
            buf_byte(&tmp, (uint8_t)(hi * 16 + lo));
            break;
        }
        }
    }
    if (c->pos >= c->len) fail(c, "unterminated string");
    c->pos++; /* closing quote */
    char *s = arena_alloc(&c->arena, tmp.len + 1);
    memcpy(s, tmp.data, tmp.len);
    s[tmp.len] = '\0';
    *out_len = tmp.len;
    buf_free(&tmp);
    return s;
}

static SExpr *new_node(Ctx *c) {
    SExpr *n = arena_alloc(&c->arena, sizeof *n);
    memset(n, 0, sizeof *n);
    return n;
}

static void add_kid(SExpr *list, SExpr *kid) {
    if (list->last)
        list->last->next = kid;
    else
        list->first = kid;
    list->last = kid;
    list->n_kids++;
}

/* Parse one s-expression (atom or list). Returns NULL at end of input. */
static SExpr *read_sexpr(Ctx *c) {
    skip_trivia(c);
    if (c->pos >= c->len) return NULL;
    size_t tok_pos = c->pos;
    char ch = c->src[c->pos];
    if (ch == ')') fail(c, "unexpected ')'");
    if (ch == '(') {
        c->pos++;
        SExpr *list = new_node(c);
        list->is_list = 1;
        list->src_pos = tok_pos;
        for (;;) {
            skip_trivia(c);
            if (c->pos >= c->len) fail(c, "unterminated list");
            if (c->src[c->pos] == ')') {
                c->pos++;
                return list;
            }
            SExpr *kid = read_sexpr(c);
            if (!kid) fail(c, "unterminated list");
            add_kid(list, kid);
        }
    }
    /* atom */
    SExpr *n = new_node(c);
    n->src_pos = tok_pos;
    if (ch == '"') {
        n->is_string = 1;
        n->atom = read_string(c, &n->atom_len);
        return n;
    }
    size_t start = c->pos;
    while (c->pos < c->len && is_atom_char((unsigned char)c->src[c->pos])) c->pos++;
    if (c->pos == start) fail(c, "unexpected character '%c'", ch);
    size_t n_len = c->pos - start;
    char *s = arena_alloc(&c->arena, n_len + 1);
    memcpy(s, c->src + start, n_len);
    s[n_len] = '\0';
    n->atom = s;
    n->atom_len = n_len;
    return n;
}

/* --- small helpers over the tree --------------------------------------- */

static int is_atom(const SExpr *n) { return n && !n->is_list; }
static int atom_eq(const SExpr *n, const char *s) {
    return is_atom(n) && !n->is_string && strcmp(n->atom, s) == 0;
}
/* Head keyword of a list (NULL if not a keyword-headed list). */
static const char *head(const SExpr *n) {
    if (n && n->is_list && n->first && is_atom(n->first) && !n->first->is_string)
        return n->first->atom;
    return NULL;
}

/* --- numeric literal parsing ------------------------------------------- */

static uint64_t parse_uint(Ctx *c, const char *s) {
    int neg = 0;
    if (*s == '+') s++;
    else if (*s == '-') {
        neg = 1;
        s++;
    }
    uint64_t v = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
        if (!*s) fail(c, "bad hex integer");
        for (; *s; s++) {
            if (*s == '_') continue;
            int h = hexval((unsigned char)*s);
            if (h < 0) fail(c, "bad hex digit in '%s'", s);
            v = v * 16 + (uint64_t)h;
        }
    } else {
        if (!*s) fail(c, "empty integer");
        for (; *s; s++) {
            if (*s == '_') continue;
            if (*s < '0' || *s > '9') fail(c, "bad digit in integer '%s'", s);
            v = v * 10 + (uint64_t)(*s - '0');
        }
    }
    return neg ? (uint64_t)(-(int64_t)v) : v;
}

static double parse_double(Ctx *c, const char *s) {
    int neg = 0;
    const char *p = s;
    if (*p == '+') p++;
    else if (*p == '-') {
        neg = 1;
        p++;
    }
    if (strncmp(p, "inf", 3) == 0) {
        uint64_t bits = neg ? 0xfff0000000000000ull : 0x7ff0000000000000ull;
        double inf;
        memcpy(&inf, &bits, 8);
        return inf;
    }
    if (strncmp(p, "nan", 3) == 0) {
        /* nan or nan:0x<payload>; payload is not preserved in this stage. */
        uint64_t bits = 0x7ff8000000000000ull;
        if (neg) bits |= 0x8000000000000000ull;
        double d;
        memcpy(&d, &bits, 8);
        return d;
    }
    /* strtod handles decimal and C99 hex floats. Underscores aren't accepted
     * by strtod; strip them into a scratch copy if present. */
    char scratch[128];
    if (strchr(s, '_')) {
        size_t j = 0;
        for (const char *q = s; *q && j + 1 < sizeof scratch; q++)
            if (*q != '_') scratch[j++] = *q;
        scratch[j] = '\0';
        s = scratch;
    }
    char *end = NULL;
    double d = strtod(s, &end);
    if (end == s) fail(c, "bad float literal '%s'", s);
    return d;
}

/* --- value, heap, and storage types ------------------------------------ */

/* Resolve a $type / numeric token to a type index. */
static uint32_t resolve_type(Ctx *c, const SExpr *n) {
    if (!is_atom(n)) fail(c, "expected a type");
    if (n->atom[0] == '$') {
        for (size_t i = 0; i < c->n_decl_types; i++)
            if (c->decls[i].name && strcmp(c->decls[i].name, n->atom) == 0) return (uint32_t)i;
        fail(c, "unknown type '%s'", n->atom);
    }
    return (uint32_t)parse_uint(c, n->atom);
}

/* Abstract heap-type byte for a shorthand name (0 if not one). */
static uint8_t abstract_heaptype(const char *s) {
    if (!strcmp(s, "func")) return 0x70;
    if (!strcmp(s, "extern")) return 0x6f;
    if (!strcmp(s, "any")) return 0x6e;
    if (!strcmp(s, "eq")) return 0x6d;
    if (!strcmp(s, "i31")) return 0x6c;
    if (!strcmp(s, "struct")) return 0x6b;
    if (!strcmp(s, "array")) return 0x6a;
    if (!strcmp(s, "none")) return 0x71;
    if (!strcmp(s, "nofunc")) return 0x73;
    if (!strcmp(s, "noextern")) return 0x72;
    if (!strcmp(s, "exn")) return 0x69;
    if (!strcmp(s, "noexn")) return 0x74;
    return 0;
}

/* A heap type: an abstract name (negative-sleb byte) or a concrete type
 * (non-negative sleb index). */
static void emit_heaptype(Ctx *c, const SExpr *n, Buf *out) {
    if (!is_atom(n)) fail(c, "expected a heap type");
    if (n->atom[0] != '$') {
        uint8_t b = abstract_heaptype(n->atom);
        if (b) {
            buf_byte(out, b);
            return;
        }
    }
    buf_sleb(out, (int64_t)resolve_type(c, n));
}

/* Value-type byte for an abstract reference shorthand (0 if not one). */
static uint8_t abstract_reftype(const char *s) {
    if (!strcmp(s, "funcref")) return 0x70;
    if (!strcmp(s, "externref")) return 0x6f;
    if (!strcmp(s, "anyref")) return 0x6e;
    if (!strcmp(s, "eqref")) return 0x6d;
    if (!strcmp(s, "i31ref")) return 0x6c;
    if (!strcmp(s, "structref")) return 0x6b;
    if (!strcmp(s, "arrayref")) return 0x6a;
    if (!strcmp(s, "nullref")) return 0x71;
    if (!strcmp(s, "nullfuncref")) return 0x73;
    if (!strcmp(s, "nullexternref")) return 0x72;
    if (!strcmp(s, "exnref")) return 0x69;
    if (!strcmp(s, "nullexnref")) return 0x74;
    return 0;
}

/* A value type: numeric, an abstract ref shorthand, or (ref [null] heaptype). */
static void emit_valtype(Ctx *c, const SExpr *n, Buf *out) {
    if (is_atom(n)) {
        const char *s = n->atom;
        if (!strcmp(s, "i32")) {
            buf_byte(out, 0x7f);
            return;
        }
        if (!strcmp(s, "i64")) {
            buf_byte(out, 0x7e);
            return;
        }
        if (!strcmp(s, "f32")) {
            buf_byte(out, 0x7d);
            return;
        }
        if (!strcmp(s, "f64")) {
            buf_byte(out, 0x7c);
            return;
        }
        uint8_t r = abstract_reftype(s);
        if (r) {
            buf_byte(out, r);
            return;
        }
        fail(c, "unsupported value type '%s'", s);
    }
    if (head(n) && strcmp(head(n), "ref") == 0) {
        const SExpr *k = n->first->next;
        int nullable = 0;
        if (atom_eq(k, "null")) {
            nullable = 1;
            k = k->next;
        }
        if (!k) fail(c, "(ref ...) needs a heap type");
        buf_byte(out, nullable ? 0x63 : 0x64);
        emit_heaptype(c, k, out);
        return;
    }
    fail(c, "expected a value type");
}

/* A storage type: a packed type (i8/i16) or a value type. */
static void emit_storagetype(Ctx *c, const SExpr *n, Buf *out) {
    if (is_atom(n)) {
        if (!strcmp(n->atom, "i8")) {
            buf_byte(out, 0x78);
            return;
        }
        if (!strcmp(n->atom, "i16")) {
            buf_byte(out, 0x77);
            return;
        }
    }
    emit_valtype(c, n, out);
}

/* Encode one value type and copy it into a freshly malloc'd buffer. */
static void valtype_bytes(Ctx *c, const SExpr *n, uint8_t **out, size_t *len) {
    Buf t;
    buf_init(&t);
    emit_valtype(c, n, &t);
    *out = xreserve(t.len);
    memcpy(*out, t.data, t.len);
    *len = t.len;
    buf_free(&t);
}

/* --- function signatures (type section) -------------------------------- */

/* A function signature, with params/results stored as the *encoded* value-type
 * bytes (concatenated) plus their counts. Storing bytes lets reference types,
 * which are multi-byte, intern and emit uniformly. */
typedef struct {
    uint8_t *params;
    size_t params_len, n_params;
    uint8_t *results;
    size_t results_len, n_results;
} FuncSig;

typedef struct SigTable {
    FuncSig *sigs;
    size_t n, cap;
} SigTable;

/* Intern a func signature, returning its (synthesized-table-local) index. The
 * table keeps its own copies, so callers retain ownership of their buffers. */
static uint32_t sig_intern(SigTable *t, const uint8_t *params, size_t plen, size_t np,
                           const uint8_t *results, size_t rlen, size_t nr) {
    for (size_t i = 0; i < t->n; i++)
        if (t->sigs[i].n_params == np && t->sigs[i].n_results == nr &&
            t->sigs[i].params_len == plen && t->sigs[i].results_len == rlen &&
            memcmp(t->sigs[i].params, params, plen) == 0 &&
            memcmp(t->sigs[i].results, results, rlen) == 0)
            return (uint32_t)i;
    if (t->n == t->cap) {
        t->cap = t->cap ? t->cap * 2 : 8;
        t->sigs = xgrow(t->sigs, t->cap * sizeof *t->sigs);
    }
    FuncSig *s = &t->sigs[t->n];
    s->n_params = np;
    s->params_len = plen;
    s->params = plen ? xreserve(plen) : NULL;
    memcpy(s->params, params, plen);
    s->n_results = nr;
    s->results_len = rlen;
    s->results = rlen ? xreserve(rlen) : NULL;
    memcpy(s->results, results, rlen);
    return (uint32_t)t->n++;
}

static void sig_table_free(SigTable *t) {
    for (size_t i = 0; i < t->n; i++) {
        free(t->sigs[i].params);
        free(t->sigs[i].results);
    }
    free(t->sigs);
}

/* --- per-function state ------------------------------------------------ */

typedef struct {
    const char *name; /* $id, or NULL */
    uint8_t *type;    /* encoded value-type bytes (owned) */
    size_t type_len;
} Local;

typedef struct {
    Local *locals; /* params then declared locals */
    size_t n_locals, cap_locals;
    size_t n_params;
    /* control-frame label stack; index 0 outermost, last innermost. */
    const char **labels;
    size_t n_labels, cap_labels;
} FuncCtx;

static void fc_push_label(FuncCtx *f, const char *name) {
    if (f->n_labels == f->cap_labels) {
        f->cap_labels = f->cap_labels ? f->cap_labels * 2 : 8;
        f->labels = xgrow(f->labels, f->cap_labels * sizeof *f->labels);
    }
    f->labels[f->n_labels++] = name;
}

static void fc_pop_label(FuncCtx *f) { f->n_labels--; }

/* Takes ownership of `type` (a malloc'd encoded value-type buffer). */
static void fc_add_local(FuncCtx *f, const char *name, uint8_t *type, size_t type_len) {
    if (f->n_locals == f->cap_locals) {
        f->cap_locals = f->cap_locals ? f->cap_locals * 2 : 8;
        f->locals = xgrow(f->locals, f->cap_locals * sizeof *f->locals);
    }
    f->locals[f->n_locals].name = name;
    f->locals[f->n_locals].type = type;
    f->locals[f->n_locals].type_len = type_len;
    f->n_locals++;
}

static uint32_t resolve_local(Ctx *c, FuncCtx *f, const SExpr *n) {
    if (!is_atom(n)) fail(c, "expected local index");
    if (n->atom[0] == '$') {
        for (size_t i = 0; i < f->n_locals; i++)
            if (f->locals[i].name && strcmp(f->locals[i].name, n->atom) == 0)
                return (uint32_t)i;
        fail(c, "unknown local '%s'", n->atom);
    }
    return (uint32_t)parse_uint(c, n->atom);
}

/* Branch label -> relative depth (0 = innermost enclosing frame). */
static uint32_t resolve_label(Ctx *c, FuncCtx *f, const SExpr *n) {
    if (!is_atom(n)) fail(c, "expected branch label");
    if (n->atom[0] == '$') {
        for (size_t i = f->n_labels; i-- > 0;)
            if (f->labels[i] && strcmp(f->labels[i], n->atom) == 0)
                return (uint32_t)(f->n_labels - 1 - i);
        fail(c, "unknown label '%s'", n->atom);
    }
    return (uint32_t)parse_uint(c, n->atom);
}

static uint32_t resolve_index(Ctx *c, const char **names, size_t n_names, const SExpr *n,
                              const char *what) {
    if (!is_atom(n)) fail(c, "expected %s index", what);
    if (n->atom[0] == '$') {
        for (size_t i = 0; i < n_names; i++)
            if (names[i] && strcmp(names[i], n->atom) == 0) return (uint32_t)i;
        fail(c, "unknown %s '%s'", what, n->atom);
    }
    return (uint32_t)parse_uint(c, n->atom);
}

/* --- instruction table (zero-immediate opcodes) ------------------------ */

typedef struct {
    const char *name;
    uint8_t op;
} OpEntry;

/* Single-byte instructions whose only inputs are folded operands. */
static const OpEntry OPS[] = {
    {"unreachable", 0x00},
    {"nop", 0x01},
    {"drop", 0x1a},
    {"select", 0x1b},
    {"return", 0x0f},
    /* i32 */
    {"i32.eqz", 0x45},
    {"i32.eq", 0x46},
    {"i32.ne", 0x47},
    {"i32.lt_s", 0x48},
    {"i32.lt_u", 0x49},
    {"i32.gt_s", 0x4a},
    {"i32.gt_u", 0x4b},
    {"i32.le_s", 0x4c},
    {"i32.le_u", 0x4d},
    {"i32.ge_s", 0x4e},
    {"i32.ge_u", 0x4f},
    {"i32.add", 0x6a},
    {"i32.sub", 0x6b},
    {"i32.mul", 0x6c},
    {"i32.div_s", 0x6d},
    {"i32.div_u", 0x6e},
    {"i32.rem_s", 0x6f},
    {"i32.rem_u", 0x70},
    {"i32.and", 0x71},
    {"i32.or", 0x72},
    {"i32.xor", 0x73},
    {"i32.shl", 0x74},
    {"i32.shr_s", 0x75},
    {"i32.shr_u", 0x76},
    {"i32.rotl", 0x77},
    {"i32.rotr", 0x78},
    /* i64 */
    {"i64.eqz", 0x50},
    {"i64.eq", 0x51},
    {"i64.ne", 0x52},
    {"i64.lt_s", 0x53},
    {"i64.lt_u", 0x54},
    {"i64.gt_s", 0x55},
    {"i64.gt_u", 0x56},
    {"i64.le_s", 0x57},
    {"i64.le_u", 0x58},
    {"i64.ge_s", 0x59},
    {"i64.ge_u", 0x5a},
    {"i64.add", 0x7c},
    {"i64.sub", 0x7d},
    {"i64.mul", 0x7e},
    {"i64.div_s", 0x7f},
    {"i64.div_u", 0x80},
    {"i64.rem_s", 0x81},
    {"i64.rem_u", 0x82},
    {"i64.and", 0x83},
    {"i64.or", 0x84},
    {"i64.xor", 0x85},
    {"i64.shl", 0x86},
    {"i64.shr_s", 0x87},
    {"i64.shr_u", 0x88},
    {"i64.rotl", 0x89},
    {"i64.rotr", 0x8a},
    /* f32 */
    {"f32.eq", 0x5b},
    {"f32.ne", 0x5c},
    {"f32.lt", 0x5d},
    {"f32.gt", 0x5e},
    {"f32.le", 0x5f},
    {"f32.ge", 0x60},
    {"f32.abs", 0x8b},
    {"f32.neg", 0x8c},
    {"f32.ceil", 0x8d},
    {"f32.floor", 0x8e},
    {"f32.trunc", 0x8f},
    {"f32.nearest", 0x90},
    {"f32.sqrt", 0x91},
    {"f32.add", 0x92},
    {"f32.sub", 0x93},
    {"f32.mul", 0x94},
    {"f32.div", 0x95},
    {"f32.min", 0x96},
    {"f32.max", 0x97},
    {"f32.copysign", 0x98},
    /* f64 */
    {"f64.eq", 0x61},
    {"f64.ne", 0x62},
    {"f64.lt", 0x63},
    {"f64.gt", 0x64},
    {"f64.le", 0x65},
    {"f64.ge", 0x66},
    {"f64.abs", 0x99},
    {"f64.neg", 0x9a},
    {"f64.ceil", 0x9b},
    {"f64.floor", 0x9c},
    {"f64.trunc", 0x9d},
    {"f64.nearest", 0x9e},
    {"f64.sqrt", 0x9f},
    {"f64.add", 0xa0},
    {"f64.sub", 0xa1},
    {"f64.mul", 0xa2},
    {"f64.div", 0xa3},
    {"f64.min", 0xa4},
    {"f64.max", 0xa5},
    {"f64.copysign", 0xa6},
    /* conversions */
    {"i32.wrap_i64", 0xa7},
    {"i32.trunc_f64_s", 0xaa},
    {"i32.trunc_f64_u", 0xab},
    {"i64.extend_i32_s", 0xac},
    {"i64.extend_i32_u", 0xad},
    {"i64.trunc_f64_s", 0xb0},
    {"i64.trunc_f64_u", 0xb1},
    {"f64.convert_i32_s", 0xb7},
    {"f64.convert_i32_u", 0xb8},
    {"f64.convert_i64_s", 0xb9},
    {"f64.convert_i64_u", 0xba},
    {"f64.promote_f32", 0xbb},
    {"f32.demote_f64", 0xb6},
    {"f32.convert_i32_s", 0xb2},
    {"f32.convert_i64_s", 0xb4},
    {"i32.reinterpret_f32", 0xbc},
    {"i64.reinterpret_f64", 0xbd},
    {"f32.reinterpret_i32", 0xbe},
    {"f64.reinterpret_i64", 0xbf},
};

static const OpEntry *find_op(const char *name) {
    for (size_t i = 0; i < sizeof OPS / sizeof OPS[0]; i++)
        if (strcmp(OPS[i].name, name) == 0) return &OPS[i];
    return NULL;
}

/* --- block types ------------------------------------------------------- */

#define MAX_BLOCKTYPE 128

typedef struct {
    int has_type;        /* (type $t) form */
    uint32_t type_index; /* declared index when has_type */
    uint8_t params[MAX_BLOCKTYPE];
    size_t params_len, np;
    uint8_t results[MAX_BLOCKTYPE];
    size_t results_len, nr;
} BlockType;

/* Append one encoded value type to a fixed byte array, bumping its count. */
static void bt_add(Ctx *c, const SExpr *tn, uint8_t *arr, size_t *len, size_t *count) {
    Buf t;
    buf_init(&t);
    emit_valtype(c, tn, &t);
    if (*len + t.len > MAX_BLOCKTYPE) {
        buf_free(&t);
        fail(c, "block type too large");
    }
    memcpy(arr + *len, t.data, t.len);
    *len += t.len;
    (*count)++;
    buf_free(&t);
}

/* Collect the value types in a (param ...) / (result ...) group. */
static void collect_valtypes(Ctx *c, const SExpr *grp, uint8_t *arr, size_t *len, size_t *count) {
    const SExpr *k = grp->first->next;
    if (k && is_atom(k) && k->atom[0] == '$') {
        bt_add(c, k->next, arr, len, count);
        return;
    }
    for (; k; k = k->next) bt_add(c, k, arr, len, count);
}

/* Parse leading (type)/(param)/(result) forms of a block/loop/if into `bt`;
 * return the first child that is not part of the type signature. */
static const SExpr *parse_blocktype(Ctx *c, const SExpr *k, BlockType *bt) {
    memset(bt, 0, sizeof *bt);
    for (; k; k = k->next) {
        const char *h = head(k);
        if (h && strcmp(h, "param") == 0)
            collect_valtypes(c, k, bt->params, &bt->params_len, &bt->np);
        else if (h && strcmp(h, "result") == 0)
            collect_valtypes(c, k, bt->results, &bt->results_len, &bt->nr);
        else if (h && strcmp(h, "type") == 0) {
            bt->has_type = 1;
            bt->type_index = resolve_type(c, k->first->next);
        } else
            break;
    }
    return k;
}

static void emit_blocktype(Ctx *c, const BlockType *bt, Buf *out) {
    if (bt->has_type) {
        buf_sleb(out, (int64_t)bt->type_index);
    } else if (bt->np == 0 && bt->nr == 0) {
        buf_byte(out, 0x40); /* empty */
    } else if (bt->np == 0 && bt->nr == 1) {
        buf_bytes(out, bt->results, bt->results_len); /* single value type */
    } else {
        uint32_t idx = sig_intern(c->sigs, bt->params, bt->params_len, bt->np, bt->results,
                                  bt->results_len, bt->nr);
        buf_sleb(out, (int64_t)map_typeidx(c, (uint32_t)(c->n_decl_types + idx)));
    }
}

/* Resolve a struct field reference ($name or numeric) to a field index. */
static uint32_t resolve_field(Ctx *c, uint32_t tidx, const SExpr *n) {
    if (!is_atom(n)) fail(c, "expected a field index");
    if (n->atom[0] == '$') {
        if (tidx >= c->n_decl_types) fail(c, "field name on a non-struct type");
        const DeclType *d = &c->decls[tidx];
        for (size_t i = 0; i < d->n_fields; i++)
            if (d->field_names[i] && strcmp(d->field_names[i], n->atom) == 0) return (uint32_t)i;
        fail(c, "unknown field '%s'", n->atom);
    }
    return (uint32_t)parse_uint(c, n->atom);
}

/* For ref.test / ref.cast: split a (ref [null] heaptype) immediate into its
 * nullability and heap-type node. */
static const SExpr *reftype_parts(Ctx *c, const SExpr *n, int *nullable) {
    if (!(head(n) && strcmp(head(n), "ref") == 0)) fail(c, "expected a (ref ...) type");
    const SExpr *k = n->first->next;
    *nullable = 0;
    if (atom_eq(k, "null")) {
        *nullable = 1;
        k = k->next;
    }
    if (!k) fail(c, "(ref ...) needs a heap type");
    return k;
}

/* --- instruction encoding ---------------------------------------------- */

static void encode_instr(Ctx *c, FuncCtx *f, const SExpr *n, Buf *out);
/* Encode an instruction sequence [first .. stop), handling both folded
 * (parenthesized) and plain (flat) instructions. stop==NULL means to the end.
 * Returns the last instruction node emitted (NULL if none). */
static const SExpr *encode_seq(Ctx *c, FuncCtx *f, const SExpr *first, const SExpr *stop, Buf *out);
/* Encode a block/loop/if/function body, appending an `unreachable` when the
 * body cannot fall through (so the enclosing `end` validates in dead code). */
static void encode_block_body(Ctx *c, FuncCtx *f, const SExpr *first, Buf *out);

/* Whether control cannot fall through this instruction to the next. Handles
 * direct transfers and loops (a loop is exited only by falling through its
 * body, so it can't fall through if its last instruction can't). Blocks/ifs
 * are conservatively treated as able to fall through. */
static int flow_unreachable(const SExpr *n) {
    const char *op = n->is_list ? head(n) : (n->is_string ? NULL : n->atom);
    if (!op) return 0;
    if (strcmp(op, "unreachable") == 0 || strcmp(op, "br") == 0 || strcmp(op, "br_table") == 0 ||
        strcmp(op, "return") == 0 || strcmp(op, "return_call") == 0 ||
        strcmp(op, "return_call_ref") == 0 || strcmp(op, "throw") == 0 ||
        strcmp(op, "throw_ref") == 0)
        return 1;
    if (strcmp(op, "loop") == 0 && n->is_list && n->last) return flow_unreachable(n->last);
    return 0;
}

/* Encode every operand child in [from .. end). Folded operands are always
 * parenthesized sub-instructions. */
static void encode_operands(Ctx *c, FuncCtx *f, const SExpr *from, Buf *out) {
    for (const SExpr *k = from; k; k = k->next) encode_instr(c, f, k, out);
}

static void encode_instr(Ctx *c, FuncCtx *f, const SExpr *n, Buf *out) {
    const char *op = head(n);
    if (!op) {
        if (is_atom(n))
            fail(c, "line %zu: expected an instruction, got atom '%s'", line_of(c, n->src_pos),
                 n->atom);
        fail(c, "line %zu: expected an instruction", line_of(c, n->src_pos));
    }
    const SExpr *arg1 = n->first->next;

    /* Constants: opcode then a literal immediate (no folded operands). */
    if (strcmp(op, "i32.const") == 0) {
        if (!is_atom(arg1)) fail(c, "i32.const needs a literal");
        buf_byte(out, 0x41);
        buf_sleb(out, (int64_t)(int32_t)(uint32_t)parse_uint(c, arg1->atom));
        return;
    }
    if (strcmp(op, "i64.const") == 0) {
        if (!is_atom(arg1)) fail(c, "i64.const needs a literal");
        buf_byte(out, 0x42);
        buf_sleb(out, (int64_t)parse_uint(c, arg1->atom));
        return;
    }
    if (strcmp(op, "f32.const") == 0) {
        if (!is_atom(arg1)) fail(c, "f32.const needs a literal");
        buf_byte(out, 0x43);
        buf_f32(out, (float)parse_double(c, arg1->atom));
        return;
    }
    if (strcmp(op, "f64.const") == 0) {
        if (!is_atom(arg1)) fail(c, "f64.const needs a literal");
        buf_byte(out, 0x44);
        buf_f64(out, parse_double(c, arg1->atom));
        return;
    }

    /* Local accessors: index immediate, then any folded operands. */
    if (strcmp(op, "local.get") == 0 || strcmp(op, "local.set") == 0 ||
        strcmp(op, "local.tee") == 0) {
        uint32_t idx = resolve_local(c, f, arg1);
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, op[6] == 'g' ? 0x20 : op[6] == 's' ? 0x21
                                                         : 0x22);
        buf_uleb(out, idx);
        return;
    }

    /* Global accessors. */
    if (strcmp(op, "global.get") == 0 || strcmp(op, "global.set") == 0) {
        uint32_t idx = resolve_index(c, c->global_names, c->n_global_names, arg1, "global");
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, op[7] == 'g' ? 0x23 : 0x24);
        buf_uleb(out, map_global(c, idx));
        return;
    }

    /* Calls: function-index immediate, then folded argument operands. */
    if (strcmp(op, "call") == 0 || strcmp(op, "return_call") == 0) {
        uint32_t idx = resolve_index(c, c->func_names, c->n_func_names, arg1, "function");
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, op[0] == 'c' ? 0x10 : 0x12);
        buf_uleb(out, map_func(c, idx));
        return;
    }

    /* Indirect calls through a typed function reference. Operands (args then
     * the funcref) come first, then the type index. */
    if (strcmp(op, "call_ref") == 0 || strcmp(op, "return_call_ref") == 0) {
        uint32_t t = resolve_type(c, arg1);
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, op[0] == 'c' ? 0x14 : 0x15);
        buf_uleb(out, t);
        return;
    }

    /* throw $tag : operands then 0x08 tagidx. throw_ref : operand then 0x0A. */
    if (strcmp(op, "throw") == 0) {
        uint32_t t = resolve_index(c, c->tag_names, c->n_tag_names, arg1, "tag");
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, 0x08);
        buf_uleb(out, t);
        return;
    }
    if (strcmp(op, "throw_ref") == 0) {
        encode_operands(c, f, arg1, out);
        buf_byte(out, 0x0a);
        return;
    }

    /* Branches: label immediate, then folded operands (a branch value). */
    if (strcmp(op, "br") == 0 || strcmp(op, "br_if") == 0) {
        uint32_t depth = resolve_label(c, f, arg1);
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, strcmp(op, "br") == 0 ? 0x0c : 0x0d);
        buf_uleb(out, depth);
        return;
    }

    /* br_table: leading label atoms (table entries + trailing default), then a
     * folded index operand. */
    if (strcmp(op, "br_table") == 0) {
        size_t n_labels = 0;
        const SExpr *operand = arg1;
        for (; operand && is_atom(operand); operand = operand->next) n_labels++;
        if (n_labels < 1) fail(c, "br_table needs at least a default label");
        encode_operands(c, f, operand, out);
        buf_byte(out, 0x0e);
        buf_uleb(out, n_labels - 1); /* table length; the last label is default */
        for (const SExpr *l = arg1; l && is_atom(l); l = l->next)
            buf_uleb(out, resolve_label(c, f, l));
        return;
    }

    /* Structured control: block / loop. */
    if (strcmp(op, "block") == 0 || strcmp(op, "loop") == 0) {
        const SExpr *k = arg1;
        const char *label = NULL;
        if (k && is_atom(k) && k->atom[0] == '$') {
            label = k->atom;
            k = k->next;
        }
        BlockType bt;
        k = parse_blocktype(c, k, &bt);
        buf_byte(out, op[0] == 'b' ? 0x02 : 0x03);
        emit_blocktype(c, &bt, out);
        fc_push_label(f, label);
        encode_block_body(c, f, k, out);
        fc_pop_label(f);
        buf_byte(out, 0x0b);
        return;
    }

    /* Folded if: (if label? blocktype? cond... (then ...) (else ...)?).
     * The condition is encoded first, then the if opcode + block type. */
    if (strcmp(op, "if") == 0) {
        const SExpr *k = arg1;
        const char *label = NULL;
        if (k && is_atom(k) && k->atom[0] == '$') {
            label = k->atom;
            k = k->next;
        }
        BlockType bt;
        k = parse_blocktype(c, k, &bt);
        const SExpr *cond = k, *thenN = NULL, *elseN = NULL;
        for (const SExpr *p = k; p; p = p->next) {
            const char *h = head(p);
            if (h && strcmp(h, "then") == 0)
                thenN = p;
            else if (h && strcmp(h, "else") == 0)
                elseN = p;
        }
        if (!thenN) fail(c, "if without a (then ...) branch");
        encode_seq(c, f, cond, thenN, out);
        buf_byte(out, 0x04);
        emit_blocktype(c, &bt, out);
        fc_push_label(f, label);
        encode_block_body(c, f, thenN->first->next, out);
        if (elseN) {
            buf_byte(out, 0x05);
            encode_block_body(c, f, elseN->first->next, out);
        }
        fc_pop_label(f);
        buf_byte(out, 0x0b);
        return;
    }

    /* try_table: 0x1F blocktype vec(catch) body... end. Handler labels resolve
     * in the *surrounding* context (the try_table's own frame is not counted),
     * so they are resolved before pushing the body label. */
    if (strcmp(op, "try_table") == 0) {
        const SExpr *k = arg1;
        const char *label = NULL;
        if (k && is_atom(k) && k->atom[0] == '$') {
            label = k->atom;
            k = k->next;
        }
        BlockType bt;
        k = parse_blocktype(c, k, &bt);
        /* Separate leading catch clauses from the body. */
        const SExpr *catches = k, *body = k;
        size_t n_catch = 0;
        for (; body; body = body->next) {
            const char *h = head(body);
            if (h && (strcmp(h, "catch") == 0 || strcmp(h, "catch_ref") == 0 ||
                      strcmp(h, "catch_all") == 0 || strcmp(h, "catch_all_ref") == 0))
                n_catch++;
            else
                break;
        }
        buf_byte(out, 0x1f);
        emit_blocktype(c, &bt, out);
        buf_uleb(out, n_catch);
        for (const SExpr *p = catches; p != body; p = p->next) {
            const char *h = head(p);
            const SExpr *a = p->first->next;
            if (strcmp(h, "catch") == 0) {
                uint32_t tag = resolve_index(c, c->tag_names, c->n_tag_names, a, "tag");
                buf_byte(out, 0x00);
                buf_uleb(out, tag);
                buf_uleb(out, resolve_label(c, f, a->next));
            } else if (strcmp(h, "catch_ref") == 0) {
                uint32_t tag = resolve_index(c, c->tag_names, c->n_tag_names, a, "tag");
                buf_byte(out, 0x01);
                buf_uleb(out, tag);
                buf_uleb(out, resolve_label(c, f, a->next));
            } else if (strcmp(h, "catch_all") == 0) {
                buf_byte(out, 0x02);
                buf_uleb(out, resolve_label(c, f, a));
            } else { /* catch_all_ref */
                buf_byte(out, 0x03);
                buf_uleb(out, resolve_label(c, f, a));
            }
        }
        fc_push_label(f, label);
        encode_block_body(c, f, body, out);
        fc_pop_label(f);
        buf_byte(out, 0x0b);
        return;
    }

    /* --- WasmGC -------------------------------------------------------- */
    if (strcmp(op, "ref.null") == 0) {
        buf_byte(out, 0xd0);
        emit_heaptype(c, arg1, out);
        return;
    }
    if (strcmp(op, "ref.func") == 0) {
        uint32_t fi = resolve_index(c, c->func_names, c->n_func_names, arg1, "function");
        buf_byte(out, 0xd2);
        buf_uleb(out, map_func(c, fi));
        return;
    }
    if (strcmp(op, "ref.is_null") == 0) {
        encode_operands(c, f, arg1, out);
        buf_byte(out, 0xd1);
        return;
    }
    if (strcmp(op, "ref.as_non_null") == 0) {
        encode_operands(c, f, arg1, out);
        buf_byte(out, 0xd4);
        return;
    }
    if (strcmp(op, "ref.eq") == 0) {
        encode_operands(c, f, arg1, out);
        buf_byte(out, 0xd3);
        return;
    }
    if (strcmp(op, "ref.i31") == 0 || strcmp(op, "i31.get_s") == 0 ||
        strcmp(op, "i31.get_u") == 0) {
        encode_operands(c, f, arg1, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, op[0] == 'r' ? 0x1c : op[8] == 's' ? 0x1d
                                                         : 0x1e);
        return;
    }
    if (strcmp(op, "ref.test") == 0 || strcmp(op, "ref.cast") == 0) {
        int nullable;
        const SExpr *ht = reftype_parts(c, arg1, &nullable);
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, 0xfb);
        if (strcmp(op, "ref.test") == 0)
            buf_uleb(out, nullable ? 0x15 : 0x14);
        else
            buf_uleb(out, nullable ? 0x17 : 0x16);
        emit_heaptype(c, ht, out);
        return;
    }
    if (strcmp(op, "struct.new") == 0 || strcmp(op, "struct.new_default") == 0) {
        uint32_t t = resolve_type(c, arg1);
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, strcmp(op, "struct.new") == 0 ? 0x00 : 0x01);
        buf_uleb(out, t);
        return;
    }
    if (strcmp(op, "struct.get") == 0 || strcmp(op, "struct.get_s") == 0 ||
        strcmp(op, "struct.get_u") == 0) {
        uint32_t t = resolve_type(c, arg1);
        uint32_t fld = resolve_field(c, t, arg1->next);
        encode_operands(c, f, arg1->next->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, strcmp(op, "struct.get") == 0     ? 0x02
                      : strcmp(op, "struct.get_s") == 0 ? 0x03
                                                        : 0x04);
        buf_uleb(out, t);
        buf_uleb(out, fld);
        return;
    }
    if (strcmp(op, "struct.set") == 0) {
        uint32_t t = resolve_type(c, arg1);
        uint32_t fld = resolve_field(c, t, arg1->next);
        encode_operands(c, f, arg1->next->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, 0x05);
        buf_uleb(out, t);
        buf_uleb(out, fld);
        return;
    }
    if (strcmp(op, "array.new") == 0 || strcmp(op, "array.new_default") == 0) {
        uint32_t t = resolve_type(c, arg1);
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, strcmp(op, "array.new") == 0 ? 0x06 : 0x07);
        buf_uleb(out, t);
        return;
    }
    if (strcmp(op, "array.new_data") == 0) {
        uint32_t t = resolve_type(c, arg1);
        uint32_t d = resolve_index(c, c->data_names, c->n_data_names, arg1->next, "data segment");
        encode_operands(c, f, arg1->next->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, 0x09);
        buf_uleb(out, t);
        buf_uleb(out, d);
        return;
    }
    if (strcmp(op, "array.new_fixed") == 0) {
        uint32_t t = resolve_type(c, arg1);
        const SExpr *nnode = arg1->next;
        if (!is_atom(nnode)) fail(c, "array.new_fixed needs an element count");
        uint64_t count = parse_uint(c, nnode->atom);
        encode_operands(c, f, nnode->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, 0x08);
        buf_uleb(out, t);
        buf_uleb(out, count);
        return;
    }
    if (strcmp(op, "array.get") == 0 || strcmp(op, "array.get_s") == 0 ||
        strcmp(op, "array.get_u") == 0) {
        uint32_t t = resolve_type(c, arg1);
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, strcmp(op, "array.get") == 0     ? 0x0b
                      : strcmp(op, "array.get_s") == 0 ? 0x0c
                                                       : 0x0d);
        buf_uleb(out, t);
        return;
    }
    if (strcmp(op, "array.set") == 0 || strcmp(op, "array.fill") == 0) {
        uint32_t t = resolve_type(c, arg1);
        encode_operands(c, f, arg1->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, strcmp(op, "array.set") == 0 ? 0x0e : 0x10);
        buf_uleb(out, t);
        return;
    }
    if (strcmp(op, "array.len") == 0) {
        encode_operands(c, f, arg1, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, 0x0f);
        return;
    }
    if (strcmp(op, "array.copy") == 0) {
        uint32_t dt = resolve_type(c, arg1);
        uint32_t st = resolve_type(c, arg1->next);
        encode_operands(c, f, arg1->next->next, out);
        buf_byte(out, 0xfb);
        buf_uleb(out, 0x11);
        buf_uleb(out, dt);
        buf_uleb(out, st);
        return;
    }

    /* Zero-immediate ops: encode folded operands, then the opcode. */
    const OpEntry *e = find_op(op);
    if (e) {
        encode_operands(c, f, arg1, out);
        buf_byte(out, e->op);
        return;
    }

    fail(c, "line %zu: unsupported instruction '%s'", line_of(c, n->src_pos), op);
}

/* Number of immediate atoms a plain (flat) instruction consumes from the
 * sibling stream, or -1 if the opcode cannot appear in plain form here
 * (structured control and reftype-immediate ops are always folded). */
static int plain_imm_count(const char *op) {
    if (!strcmp(op, "block") || !strcmp(op, "loop") || !strcmp(op, "if") ||
        !strcmp(op, "else") || !strcmp(op, "end") || !strcmp(op, "try_table") ||
        !strcmp(op, "ref.test") || !strcmp(op, "ref.cast") || !strcmp(op, "br_table"))
        return -1;
    if (!strcmp(op, "struct.get") || !strcmp(op, "struct.get_s") || !strcmp(op, "struct.get_u") ||
        !strcmp(op, "struct.set") || !strcmp(op, "array.copy") || !strcmp(op, "array.new_fixed") ||
        !strcmp(op, "array.new_data"))
        return 2;
    if (!strcmp(op, "local.get") || !strcmp(op, "local.set") || !strcmp(op, "local.tee") ||
        !strcmp(op, "global.get") || !strcmp(op, "global.set") || !strcmp(op, "call") ||
        !strcmp(op, "return_call") || !strcmp(op, "call_ref") || !strcmp(op, "return_call_ref") ||
        !strcmp(op, "br") || !strcmp(op, "br_if") || !strcmp(op, "throw") ||
        !strcmp(op, "ref.func") || !strcmp(op, "ref.null") || !strcmp(op, "i32.const") ||
        !strcmp(op, "i64.const") || !strcmp(op, "f32.const") || !strcmp(op, "f64.const") ||
        !strcmp(op, "struct.new") || !strcmp(op, "struct.new_default") || !strcmp(op, "array.new") ||
        !strcmp(op, "array.new_default") || !strcmp(op, "array.get") ||
        !strcmp(op, "array.get_s") || !strcmp(op, "array.get_u") || !strcmp(op, "array.set") ||
        !strcmp(op, "array.fill"))
        return 1;
    return 0; /* drop, return, nop, numeric ops, ref.eq, array.len, ... */
}

/* Encode a plain instruction: the opcode atom `op_node` plus its immediate
 * atoms (taken from following siblings). Builds an equivalent folded node with
 * no operand children and reuses encode_instr. Returns the next unconsumed
 * sibling. */
static const SExpr *encode_plain(Ctx *c, FuncCtx *f, const SExpr *op_node, Buf *out) {
    int cnt = plain_imm_count(op_node->atom);
    if (cnt < 0)
        fail(c, "line %zu: plain (unfolded) '%s' is not supported", line_of(c, op_node->src_pos),
             op_node->atom);
    SExpr *synth = new_node(c);
    synth->is_list = 1;
    synth->src_pos = op_node->src_pos;
    SExpr *opc = new_node(c);
    opc->atom = op_node->atom;
    opc->atom_len = op_node->atom_len;
    add_kid(synth, opc);
    const SExpr *cur = op_node->next;
    for (int i = 0; i < cnt; i++) {
        if (!cur || !is_atom(cur))
            fail(c, "line %zu: plain '%s' is missing an immediate",
                 line_of(c, op_node->src_pos), op_node->atom);
        SExpr *im = new_node(c);
        im->atom = cur->atom;
        im->atom_len = cur->atom_len;
        im->is_string = cur->is_string;
        im->src_pos = cur->src_pos;
        add_kid(synth, im);
        cur = cur->next;
    }
    encode_instr(c, f, synth, out);
    return cur;
}

static const SExpr *encode_seq(Ctx *c, FuncCtx *f, const SExpr *first, const SExpr *stop,
                               Buf *out) {
    const SExpr *k = first, *last = NULL;
    while (k && k != stop) {
        last = k;
        if (k->is_list) {
            encode_instr(c, f, k, out);
            k = k->next;
        } else {
            k = encode_plain(c, f, k, out);
        }
    }
    return last;
}

static void encode_block_body(Ctx *c, FuncCtx *f, const SExpr *first, Buf *out) {
    const SExpr *last = encode_seq(c, f, first, NULL, out);
    if (last && flow_unreachable(last)) buf_byte(out, 0x00); /* unreachable */
}

/* --- function parsing -------------------------------------------------- */

typedef struct {
    const char *name;        /* $id or NULL */
    const char *export_name; /* decoded export string or NULL */
    size_t export_len;
    int has_type_ref;    /* references a declared type via (type $x) */
    uint32_t type_ref;   /* the declared index, when has_type_ref */
    uint32_t type_index; /* final type index, assigned in assemble() */
    FuncSig sig;         /* the inline signature (also used to intern) */
    FuncCtx fc;
    const SExpr *body_first; /* first body instruction node */
} Func;

/* Collect a (param ...) / (result ...) / (local ...) group. When `sig` is
 * non-NULL the encoded value types are appended to it (and counted into
 * *count); when `f` is non-NULL the entries also become locals. */
static void collect_group(Ctx *c, const SExpr *grp, Buf *sig, size_t *count, FuncCtx *f,
                          int is_param) {
    const SExpr *k = grp->first->next;
    int named = (k && is_atom(k) && k->atom[0] == '$');
    if (named) {
        const SExpr *tn = k->next;
        if (sig) {
            emit_valtype(c, tn, sig);
            (*count)++;
        }
        if (f) {
            uint8_t *tb;
            size_t tl;
            valtype_bytes(c, tn, &tb, &tl);
            fc_add_local(f, k->atom, tb, tl);
            if (is_param) f->n_params++;
        }
        return;
    }
    for (; k; k = k->next) {
        if (sig) {
            emit_valtype(c, k, sig);
            (*count)++;
        }
        if (f) {
            uint8_t *tb;
            size_t tl;
            valtype_bytes(c, k, &tb, &tl);
            fc_add_local(f, NULL, tb, tl);
            if (is_param) f->n_params++;
        }
    }
}

/* Count the params declared in a (func ...) comptype node. */
static size_t count_comptype_params(const SExpr *func) {
    size_t n = 0;
    for (const SExpr *k = func->first->next; k; k = k->next) {
        if (!(head(k) && strcmp(head(k), "param") == 0)) continue;
        const SExpr *p = k->first->next;
        if (p && is_atom(p) && p->atom[0] == '$')
            n++;
        else
            for (; p; p = p->next) n++;
    }
    return n;
}

static void parse_func(Ctx *c, const SExpr *fn, Func *out) {
    memset(out, 0, sizeof *out);
    Buf params, results;
    buf_init(&params);
    buf_init(&results);
    size_t np = 0, nr = 0;
    int body_started = 0;
    for (const SExpr *k = fn->first->next; k; k = k->next) {
        if (!body_started && is_atom(k) && k->atom[0] == '$') {
            out->name = k->atom;
            continue;
        }
        const char *h = head(k);
        if (!body_started && h && strcmp(h, "export") == 0) {
            const SExpr *s = k->first->next;
            if (!s || !s->is_string) fail(c, "(export ...) needs a name string");
            out->export_name = s->atom;
            out->export_len = s->atom_len;
            continue;
        }
        if (!body_started && h && strcmp(h, "type") == 0) {
            out->has_type_ref = 1;
            out->type_ref = resolve_type(c, k->first->next);
            continue;
        }
        if (!body_started && h && strcmp(h, "param") == 0) {
            collect_group(c, k, &params, &np, &out->fc, 1);
            continue;
        }
        if (!body_started && h && strcmp(h, "result") == 0) {
            collect_group(c, k, &results, &nr, NULL, 0);
            continue;
        }
        if (!body_started && h && strcmp(h, "local") == 0) {
            collect_group(c, k, NULL, NULL, &out->fc, 0);
            continue;
        }
        body_started = 1;
        if (!out->body_first) out->body_first = k;
    }

    /* Finalize the inline signature (kept even when (type $x) is used, so the
     * func can be interned if no declared type matches). */
    out->sig.n_params = np;
    out->sig.params_len = params.len;
    out->sig.params = xreserve(params.len ? params.len : 1);
    memcpy(out->sig.params, params.data, params.len);
    out->sig.n_results = nr;
    out->sig.results_len = results.len;
    out->sig.results = xreserve(results.len ? results.len : 1);
    memcpy(out->sig.results, results.data, results.len);
    buf_free(&params);
    buf_free(&results);

    /* If a (type $x) func omits its (param ...) list, recover the param count
     * from the declared type so declared locals are indexed after the params. */
    if (out->has_type_ref && np == 0 && out->type_ref < c->n_decl_types) {
        const SExpr *ct = c->decls[out->type_ref].comptype;
        if (ct && head(ct) && strcmp(head(ct), "func") == 0) {
            size_t cnt = count_comptype_params(ct);
            for (size_t i = 0; i < cnt; i++) {
                uint8_t *ph = xreserve(1);
                ph[0] = 0x7f; /* placeholder; param types aren't re-emitted */
                fc_add_local(&out->fc, NULL, ph, 1);
                out->fc.n_params++;
            }
        }
    }
}

/* --- global parsing ---------------------------------------------------- */

typedef struct {
    const char *name; /* $id or NULL */
    uint8_t *type;    /* encoded value-type bytes (owned) */
    size_t type_len;
    int is_mut;
    const SExpr *init; /* init const-expression instruction node */
} Global;

static void parse_global(Ctx *c, const SExpr *g, Global *out) {
    memset(out, 0, sizeof *out);
    const SExpr *k = g->first->next;
    if (k && is_atom(k) && k->atom[0] == '$') {
        out->name = k->atom;
        k = k->next;
    }
    if (!k) fail(c, "global needs a type");
    if (head(k) && strcmp(head(k), "mut") == 0) {
        out->is_mut = 1;
        valtype_bytes(c, k->first->next, &out->type, &out->type_len);
    } else {
        valtype_bytes(c, k, &out->type, &out->type_len);
    }
    k = k->next;
    if (!k) fail(c, "global needs an init expression");
    out->init = k;
}

/* --- import / tag / data parsing --------------------------------------- */

/* Finalize a FuncSig from two scratch buffers, transferring ownership. */
static void sig_finalize(FuncSig *sig, Buf *params, size_t np, Buf *results, size_t nr) {
    sig->n_params = np;
    sig->params_len = params->len;
    sig->params = xreserve(params->len ? params->len : 1);
    memcpy(sig->params, params->data, params->len);
    sig->n_results = nr;
    sig->results_len = results->len;
    sig->results = xreserve(results->len ? results->len : 1);
    memcpy(sig->results, results->data, results->len);
    buf_free(params);
    buf_free(results);
}

typedef struct {
    const char *module;
    size_t module_len;
    const char *name;
    size_t name_len;
    const char *id; /* $name or NULL */
    int has_type_ref;
    uint32_t type_ref;
    FuncSig sig;
    uint32_t type_index;
} Import;

/* Parse (import "m" "n" (func $id <signature>)). Only function imports are
 * supported (the only kind the compiler emits). */
static void parse_import(Ctx *c, const SExpr *imp, Import *out) {
    memset(out, 0, sizeof *out);
    const SExpr *k = imp->first->next;
    if (!k || !k->is_string) fail(c, "import needs a module string");
    out->module = k->atom;
    out->module_len = k->atom_len;
    k = k->next;
    if (!k || !k->is_string) fail(c, "import needs a name string");
    out->name = k->atom;
    out->name_len = k->atom_len;
    k = k->next;
    if (!(head(k) && strcmp(head(k), "func") == 0))
        fail(c, "only function imports are supported");
    Buf params, results;
    buf_init(&params);
    buf_init(&results);
    size_t np = 0, nr = 0;
    for (const SExpr *d = k->first->next; d; d = d->next) {
        if (is_atom(d) && d->atom[0] == '$') {
            out->id = d->atom;
            continue;
        }
        const char *h = head(d);
        if (h && strcmp(h, "type") == 0) {
            out->has_type_ref = 1;
            out->type_ref = resolve_type(c, d->first->next);
        } else if (h && strcmp(h, "param") == 0) {
            collect_group(c, d, &params, &np, NULL, 0);
        } else if (h && strcmp(h, "result") == 0) {
            collect_group(c, d, &results, &nr, NULL, 0);
        }
    }
    sig_finalize(&out->sig, &params, np, &results, nr);
}

typedef struct {
    const char *id;
    const char *export_name;
    size_t export_len;
    FuncSig sig; /* params; no results */
    uint32_t type_index;
} Tag;

static void parse_tag(Ctx *c, const SExpr *tg, Tag *out) {
    memset(out, 0, sizeof *out);
    Buf params, results;
    buf_init(&params);
    buf_init(&results);
    size_t np = 0;
    for (const SExpr *k = tg->first->next; k; k = k->next) {
        if (is_atom(k) && k->atom[0] == '$') {
            out->id = k->atom;
            continue;
        }
        const char *h = head(k);
        if (h && strcmp(h, "export") == 0) {
            const SExpr *s = k->first->next;
            if (!s || !s->is_string) fail(c, "(export ...) needs a name string");
            out->export_name = s->atom;
            out->export_len = s->atom_len;
        } else if (h && strcmp(h, "param") == 0) {
            collect_group(c, k, &params, &np, NULL, 0);
        } else {
            fail(c, "unexpected form in (tag ...)");
        }
    }
    sig_finalize(&out->sig, &params, np, &results, 0);
}

typedef struct {
    const char *id;
    uint8_t *bytes;
    size_t len;
} DataSeg;

static void parse_data(Ctx *c, const SExpr *dn, DataSeg *out) {
    memset(out, 0, sizeof *out);
    const SExpr *k = dn->first->next;
    if (k && is_atom(k) && k->atom[0] == '$') {
        out->id = k->atom;
        k = k->next;
    }
    Buf b;
    buf_init(&b);
    for (; k; k = k->next) {
        if (!k->is_string) fail(c, "(data ...) expects only a passive byte string");
        buf_bytes(&b, k->atom, k->atom_len);
    }
    out->len = b.len;
    out->bytes = xreserve(b.len ? b.len : 1);
    memcpy(out->bytes, b.data, b.len);
    buf_free(&b);
}

/* --- block-type prewalk ------------------------------------------------ *
 * Block/loop/if/try_table signatures that need a type index must be interned
 * before the type section is written, so walk every body once up front. */
static void prewalk_instr(Ctx *c, const SExpr *n) {
    if (!n || !n->is_list) return;
    const char *op = head(n);
    if (op && (strcmp(op, "block") == 0 || strcmp(op, "loop") == 0 || strcmp(op, "if") == 0 ||
               strcmp(op, "try_table") == 0)) {
        const SExpr *k = n->first->next;
        if (k && is_atom(k) && k->atom[0] == '$') k = k->next;
        BlockType bt;
        parse_blocktype(c, k, &bt);
        if (!bt.has_type && (bt.np > 0 || bt.nr > 1))
            sig_intern(c->sigs, bt.params, bt.params_len, bt.np, bt.results, bt.results_len, bt.nr);
    }
    for (const SExpr *k = n->first ? n->first->next : NULL; k; k = k->next)
        if (k->is_list) prewalk_instr(c, k);
}

/* Mark every function reached by a (ref.func $x) in this subtree as declared,
 * so it can be the operand of ref.func (the source relies on the assembler
 * auto-declaring them, like Binaryen does). */
static void collect_reffunc(Ctx *c, const SExpr *n, uint8_t *declared) {
    if (!n || !n->is_list) return;
    const char *op = head(n);
    if (op && strcmp(op, "ref.func") == 0)
        declared[resolve_index(c, c->func_names, c->n_func_names, n->first->next, "function")] = 1;
    for (const SExpr *k = n->first ? n->first->next : NULL; k; k = k->next)
        if (k->is_list) collect_reffunc(c, k, declared);
}

/* DCE reachability worklist: a single index space, [0, n_func_names) for
 * functions and [n_func_names, ...) for globals. */
static void dce_mark(Ctx *c, uint8_t *reach, uint32_t *stack, size_t *sp, uint32_t e) {
    if (!reach[e]) {
        reach[e] = 1;
        stack[(*sp)++] = e;
    }
}

/* Mark the functions and globals referenced anywhere in an instruction
 * sequence (folded or plain). A direct call definitely runs its target; a
 * ref.func takes a function's address (reachable via call_ref); global.get /
 * global.set reference a global — all keep the target. */
static void dce_scan(Ctx *c, const SExpr *seq, uint8_t *reach, uint32_t *stack, size_t *sp) {
    uint32_t gbase = (uint32_t)c->n_func_names;
    for (const SExpr *k = seq; k; k = k->next) {
        if (k->is_list) {
            const char *op = head(k);
            const SExpr *imm = k->first ? k->first->next : NULL;
            if (op && (strcmp(op, "call") == 0 || strcmp(op, "return_call") == 0 ||
                       strcmp(op, "ref.func") == 0))
                dce_mark(c, reach, stack, sp,
                         resolve_index(c, c->func_names, c->n_func_names, imm, "function"));
            else if (op && (strcmp(op, "global.get") == 0 || strcmp(op, "global.set") == 0))
                dce_mark(c, reach, stack, sp,
                         gbase + resolve_index(c, c->global_names, c->n_global_names, imm, "global"));
            dce_scan(c, imm, reach, stack, sp);
        } else if (!k->is_string && k->next) {
            if (strcmp(k->atom, "call") == 0 || strcmp(k->atom, "return_call") == 0 ||
                strcmp(k->atom, "ref.func") == 0)
                dce_mark(c, reach, stack, sp,
                         resolve_index(c, c->func_names, c->n_func_names, k->next, "function"));
            else if (strcmp(k->atom, "global.get") == 0 || strcmp(k->atom, "global.set") == 0)
                dce_mark(c, reach, stack, sp,
                         gbase +
                             resolve_index(c, c->global_names, c->n_global_names, k->next, "global"));
        }
    }
}

/* Mark the synthesized signatures a live function's body reaches through its
 * block types (block/loop/if/try_table with a multi-value signature). Every
 * such sig was already interned by the prewalk over all functions, so the
 * sig_intern call here only re-finds the existing slot — it never grows the
 * table. Mirrors prewalk_instr/emit_blocktype so we never under-mark a sig
 * that surviving code will reference. */
static void sig_mark_blocks(Ctx *c, const SExpr *seq, uint8_t *sig_live) {
    for (const SExpr *n = seq; n; n = n->next) {
        if (!n->is_list) continue;
        const char *op = head(n);
        if (op && (strcmp(op, "block") == 0 || strcmp(op, "loop") == 0 ||
                   strcmp(op, "if") == 0 || strcmp(op, "try_table") == 0)) {
            const SExpr *k = n->first->next;
            if (k && is_atom(k) && k->atom[0] == '$') k = k->next;
            BlockType bt;
            parse_blocktype(c, k, &bt);
            if (!bt.has_type && (bt.np > 0 || bt.nr > 1)) {
                uint32_t idx = sig_intern(c->sigs, bt.params, bt.params_len, bt.np, bt.results,
                                          bt.results_len, bt.nr);
                sig_live[idx] = 1;
            }
        }
        for (const SExpr *k = n->first ? n->first->next : NULL; k; k = k->next)
            sig_mark_blocks(c, k, sig_live);
    }
}

/* --- section assembly -------------------------------------------------- */

static void put_section(Buf *module, uint8_t id, const Buf *body) {
    if (body->len == 0) return;
    buf_byte(module, id);
    buf_uleb(module, body->len);
    buf_append(module, body);
}

/* Encode a function's code entry: locals (RLE) + body + end. */
static void encode_code(Ctx *c, Func *fn, Buf *code) {
    Buf body;
    buf_init(&body);

    /* Declared locals only (params are not repeated here), RLE-compressed. */
    size_t first_local = fn->fc.n_params;
    Buf locals;
    buf_init(&locals);
    size_t groups = 0;
    for (size_t i = first_local; i < fn->fc.n_locals;) {
        size_t j = i + 1;
        while (j < fn->fc.n_locals && fn->fc.locals[j].type_len == fn->fc.locals[i].type_len &&
               memcmp(fn->fc.locals[j].type, fn->fc.locals[i].type, fn->fc.locals[i].type_len) ==
                   0)
            j++;
        buf_uleb(&locals, j - i);
        buf_bytes(&locals, fn->fc.locals[i].type, fn->fc.locals[i].type_len);
        groups++;
        i = j;
    }

    encode_block_body(c, &fn->fc, fn->body_first, &body);
    buf_byte(&body, 0x0b); /* end */

    Buf entry;
    buf_init(&entry);
    buf_uleb(&entry, groups);
    buf_append(&entry, &locals);
    buf_append(&entry, &body);

    buf_uleb(code, entry.len);
    buf_append(code, &entry);

    buf_free(&entry);
    buf_free(&locals);
    buf_free(&body);
}

/* --- declared type parsing + encoding ---------------------------------- */

/* Parse one (type $name <typedef>) node, where <typedef> is a comptype
 * (struct/array/func) optionally wrapped in (sub [final] $super* <comptype>). */
static void parse_decltype(Ctx *c, const SExpr *tn, DeclType *out) {
    memset(out, 0, sizeof *out);
    const SExpr *k = tn->first->next;
    if (k && is_atom(k) && k->atom[0] == '$') {
        out->name = k->atom;
        k = k->next;
    }
    if (!k) fail(c, "type needs a definition");
    if (head(k) && strcmp(head(k), "sub") == 0) {
        out->has_sub = 1;
        const SExpr *s = k->first->next;
        if (atom_eq(s, "final")) {
            out->is_final = 1;
            s = s->next;
        }
        for (; s; s = s->next) {
            if (is_atom(s) && s->atom[0] == '$') {
                if (out->n_supers >= 8) fail(c, "too many supertypes");
                out->supers[out->n_supers++] = s;
            } else {
                out->comptype = s;
            }
        }
        if (!out->comptype) fail(c, "(sub ...) without a type definition");
    } else {
        out->comptype = k;
    }
    /* Record struct field names so struct.get/set can resolve them by name. */
    if (head(out->comptype) && strcmp(head(out->comptype), "struct") == 0) {
        size_t cnt = 0;
        for (const SExpr *fk = out->comptype->first->next; fk; fk = fk->next) {
            if (!(head(fk) && strcmp(head(fk), "field") == 0)) continue;
            const SExpr *p = fk->first->next;
            if (p && is_atom(p) && p->atom[0] == '$')
                cnt++;
            else
                for (; p; p = p->next) cnt++;
        }
        out->n_fields = cnt;
        out->field_names = xreserve((cnt ? cnt : 1) * sizeof *out->field_names);
        size_t fi = 0;
        for (const SExpr *fk = out->comptype->first->next; fk; fk = fk->next) {
            if (!(head(fk) && strcmp(head(fk), "field") == 0)) continue;
            const SExpr *p = fk->first->next;
            if (p && is_atom(p) && p->atom[0] == '$')
                out->field_names[fi++] = p->atom;
            else
                for (; p; p = p->next) out->field_names[fi++] = NULL;
        }
    }
}

/* Emit one field type: a storage type plus a mutability byte. */
static void emit_one_field(Ctx *c, const SExpr *ft, Buf *out) {
    if (head(ft) && strcmp(head(ft), "mut") == 0) {
        emit_storagetype(c, ft->first->next, out);
        buf_byte(out, 1);
    } else {
        emit_storagetype(c, ft, out);
        buf_byte(out, 0);
    }
}

/* Emit the fields of one (field ...) group, counting them. */
static void emit_field_group(Ctx *c, const SExpr *grp, Buf *out, size_t *nf) {
    const SExpr *k = grp->first->next;
    if (k && is_atom(k) && k->atom[0] == '$') {
        emit_one_field(c, k->next, out);
        (*nf)++;
        return;
    }
    for (; k; k = k->next) {
        emit_one_field(c, k, out);
        (*nf)++;
    }
}

static void emit_comptype(Ctx *c, const SExpr *ct, Buf *out) {
    const char *h = head(ct);
    if (!h) fail(c, "invalid type definition");
    if (strcmp(h, "func") == 0) {
        Buf p, r;
        buf_init(&p);
        buf_init(&r);
        size_t np = 0, nr = 0;
        for (const SExpr *k = ct->first->next; k; k = k->next) {
            const char *kh = head(k);
            if (kh && strcmp(kh, "param") == 0)
                collect_group(c, k, &p, &np, NULL, 0);
            else if (kh && strcmp(kh, "result") == 0)
                collect_group(c, k, &r, &nr, NULL, 0);
        }
        buf_byte(out, 0x60);
        buf_uleb(out, np);
        buf_append(out, &p);
        buf_uleb(out, nr);
        buf_append(out, &r);
        buf_free(&p);
        buf_free(&r);
    } else if (strcmp(h, "struct") == 0) {
        Buf fields;
        buf_init(&fields);
        size_t nf = 0;
        for (const SExpr *k = ct->first->next; k; k = k->next)
            if (head(k) && strcmp(head(k), "field") == 0) emit_field_group(c, k, &fields, &nf);
        buf_byte(out, 0x5f);
        buf_uleb(out, nf);
        buf_append(out, &fields);
        buf_free(&fields);
    } else if (strcmp(h, "array") == 0) {
        buf_byte(out, 0x5e);
        emit_one_field(c, ct->first->next, out);
    } else {
        fail(c, "unsupported type definition '%s'", h);
    }
}

static void emit_subtype(Ctx *c, const DeclType *d, Buf *out) {
    if (d->has_sub) {
        buf_byte(out, d->is_final ? 0x4f : 0x50);
        buf_uleb(out, d->n_supers);
        for (size_t i = 0; i < d->n_supers; i++) buf_uleb(out, resolve_type(c, d->supers[i]));
    }
    emit_comptype(c, d->comptype, out);
}

/* --- top-level assembly ------------------------------------------------ */

/* A rectype entry in the type section: either an explicit rec group or a
 * single standalone type, spanning [start, start+count) declared indices. */
typedef struct {
    int is_rec;
    size_t start, count;
} TypeGroup;

static int assemble(Ctx *c, const SExpr *module, int dce, uint8_t **out_bytes, size_t *out_len) {
    if (!module || !atom_eq(module->first, "module"))
        fail(c, "expected a top-level (module ...)");

    Func *funcs = NULL;
    size_t n_funcs = 0, cap_funcs = 0;
    Global *globals = NULL;
    size_t n_globals = 0, cap_globals = 0;
    Import *imports = NULL;
    size_t n_imports = 0, cap_imports = 0;
    Tag *tags = NULL;
    size_t n_tags = 0, cap_tags = 0;
    DataSeg *datas = NULL;
    size_t n_datas = 0, cap_datas = 0;
    const SExpr **elems = NULL;
    size_t n_elems = 0, cap_elems = 0;
    DeclType *decls = NULL;
    size_t n_decls = 0, cap_decls = 0;
    TypeGroup *groups = NULL;
    size_t n_groups = 0, cap_groups = 0;
    SigTable sigs = {0};
    c->sigs = &sigs;

#define PUSH(arr, n, cap, init)                          \
    do {                                                 \
        if ((n) == (cap)) {                              \
            (cap) = (cap) ? (cap) * 2 : (init);          \
            (arr) = xgrow((arr), (cap) * sizeof *(arr)); \
        }                                                \
    } while (0)

    /* Pass A: declared types (so everything else can resolve them). */
    for (const SExpr *k = module->first->next; k; k = k->next) {
        const char *h = head(k);
        if (h && strcmp(h, "type") == 0) {
            PUSH(decls, n_decls, cap_decls, 8);
            PUSH(groups, n_groups, cap_groups, 8);
            groups[n_groups++] = (TypeGroup){.is_rec = 0, .start = n_decls, .count = 1};
            parse_decltype(c, k, &decls[n_decls++]);
        } else if (h && strcmp(h, "rec") == 0) {
            size_t start = n_decls;
            for (const SExpr *t = k->first->next; t; t = t->next) {
                if (!(head(t) && strcmp(head(t), "type") == 0)) fail(c, "(rec ...) holds types");
                PUSH(decls, n_decls, cap_decls, 8);
                parse_decltype(c, t, &decls[n_decls++]);
            }
            PUSH(groups, n_groups, cap_groups, 8);
            groups[n_groups++] = (TypeGroup){.is_rec = 1, .start = start, .count = n_decls - start};
        }
    }
    c->decls = decls;
    c->n_decl_types = n_decls;

    /* Pass B: imports, then everything else. Imports must be collected before
     * functions so the two share the function index space (imports first). */
    for (const SExpr *k = module->first->next; k; k = k->next) {
        const char *h = head(k);
        if (h && strcmp(h, "import") == 0) {
            PUSH(imports, n_imports, cap_imports, 8);
            Import *im = &imports[n_imports++];
            parse_import(c, k, im);
            im->type_index =
                im->has_type_ref
                    ? im->type_ref
                    : (uint32_t)(n_decls + sig_intern(&sigs, im->sig.params, im->sig.params_len,
                                                      im->sig.n_params, im->sig.results,
                                                      im->sig.results_len, im->sig.n_results));
        } else if (h && strcmp(h, "func") == 0) {
            PUSH(funcs, n_funcs, cap_funcs, 8);
            Func *fn = &funcs[n_funcs++];
            parse_func(c, k, fn);
            fn->type_index = fn->has_type_ref
                                 ? fn->type_ref
                                 : (uint32_t)(n_decls + sig_intern(&sigs, fn->sig.params,
                                                                   fn->sig.params_len,
                                                                   fn->sig.n_params, fn->sig.results,
                                                                   fn->sig.results_len,
                                                                   fn->sig.n_results));
        } else if (h && strcmp(h, "global") == 0) {
            PUSH(globals, n_globals, cap_globals, 8);
            parse_global(c, k, &globals[n_globals++]);
        } else if (h && strcmp(h, "tag") == 0) {
            PUSH(tags, n_tags, cap_tags, 8);
            Tag *tg = &tags[n_tags++];
            parse_tag(c, k, tg);
            tg->type_index =
                (uint32_t)(n_decls + sig_intern(&sigs, tg->sig.params, tg->sig.params_len,
                                                tg->sig.n_params, tg->sig.results,
                                                tg->sig.results_len, tg->sig.n_results));
        } else if (h && strcmp(h, "data") == 0) {
            PUSH(datas, n_datas, cap_datas, 8);
            parse_data(c, k, &datas[n_datas++]);
        } else if (h && strcmp(h, "elem") == 0) {
            PUSH(elems, n_elems, cap_elems, 8);
            elems[n_elems++] = k;
        } else if (h && (strcmp(h, "type") == 0 || strcmp(h, "rec") == 0)) {
            continue; /* handled in pass A */
        } else if (h) {
            fail(c, "unsupported module field '%s'", h);
        } else {
            fail(c, "unsupported module field");
        }
    }

    /* Name -> index tables. The function index space is imports then defined. */
    size_t n_all_funcs = n_imports + n_funcs;
    const char **func_names = xreserve((n_all_funcs ? n_all_funcs : 1) * sizeof *func_names);
    for (size_t i = 0; i < n_imports; i++) func_names[i] = imports[i].id;
    for (size_t i = 0; i < n_funcs; i++) func_names[n_imports + i] = funcs[i].name;
    const char **global_names = xreserve((n_globals ? n_globals : 1) * sizeof *global_names);
    for (size_t i = 0; i < n_globals; i++) global_names[i] = globals[i].name;
    const char **tag_names = xreserve((n_tags ? n_tags : 1) * sizeof *tag_names);
    for (size_t i = 0; i < n_tags; i++) tag_names[i] = tags[i].id;
    const char **data_names = xreserve((n_datas ? n_datas : 1) * sizeof *data_names);
    for (size_t i = 0; i < n_datas; i++) data_names[i] = datas[i].id;
    c->func_names = func_names;
    c->n_func_names = n_all_funcs;
    c->global_names = global_names;
    c->n_global_names = n_globals;
    c->tag_names = tag_names;
    c->n_tag_names = n_tags;
    c->data_names = data_names;
    c->n_data_names = n_datas;

    /* Dead-code elimination over a joint function+global reachability. Roots
     * are the exported functions; from there we follow call / ref.func edges
     * (functions) and global.get / global.set edges (globals). A global is kept
     * only if reachable code references it, so an unused builtin-closure global
     * is dropped together with the function its initializer pins via ref.func.
     * All imports are kept. The remaps renumber the survivors. The worklist
     * index space is [0, n_all_funcs) for functions then globals after. */
    uint8_t *reach = NULL;
    uint32_t *func_remap = NULL;
    uint32_t *global_remap = NULL;
    if (dce) {
        size_t universe = n_all_funcs + n_globals;
        reach = xreserve(universe ? universe : 1);
        memset(reach, 0, universe ? universe : 1);
        uint32_t *stack = xreserve((universe ? universe : 1) * sizeof *stack);
        size_t sp = 0;
        for (size_t i = 0; i < n_funcs; i++)
            if (funcs[i].export_name) dce_mark(c, reach, stack, &sp, (uint32_t)(n_imports + i));
        while (sp) {
            uint32_t e = stack[--sp];
            if (e < n_all_funcs) {
                if (e < n_imports) continue; /* imports have no body */
                dce_scan(c, funcs[e - n_imports].body_first, reach, stack, &sp);
            } else {
                dce_scan(c, globals[e - n_all_funcs].init, reach, stack, &sp);
            }
        }
        free(stack);
        func_remap = xreserve((n_all_funcs ? n_all_funcs : 1) * sizeof *func_remap);
        uint32_t nidx = 0;
        for (size_t i = 0; i < n_imports; i++) func_remap[i] = nidx++;
        for (size_t i = 0; i < n_funcs; i++) {
            uint32_t old = (uint32_t)(n_imports + i);
            func_remap[old] = reach[old] ? nidx++ : 0xffffffffu;
        }
        global_remap = xreserve((n_globals ? n_globals : 1) * sizeof *global_remap);
        uint32_t gidx = 0;
        for (size_t i = 0; i < n_globals; i++)
            global_remap[i] = reach[n_all_funcs + i] ? gidx++ : 0xffffffffu;
        c->func_remap = func_remap;
        c->global_remap = global_remap;
    }
#define FUNC_LIVE(i)   (!dce || reach[n_imports + (i)])
#define GLOBAL_LIVE(i) (!dce || reach[n_all_funcs + (i)])

    /* Intern block-signature types before emitting the type section. */
    for (size_t i = 0; i < n_funcs; i++)
        for (const SExpr *k = funcs[i].body_first; k; k = k->next) prewalk_instr(c, k);

    /* DCE over the synthesized signature table. A signature survives only if a
     * live entity uses it: an import or tag (both always kept), a live function
     * (as its type), or a block type inside a live function's body. Signatures
     * interned solely for now-dropped functions become dead weight in the type
     * section otherwise. Declared types keep their slots, so only the appended
     * signatures are compacted via sig_remap. */
    uint32_t *sig_remap = NULL;
    size_t n_live_sigs = sigs.n;
    if (dce && sigs.n) {
        uint8_t *sig_live = xreserve(sigs.n);
        memset(sig_live, 0, sigs.n);
        for (size_t i = 0; i < n_imports; i++)
            if (imports[i].type_index >= n_decls) sig_live[imports[i].type_index - n_decls] = 1;
        for (size_t i = 0; i < n_tags; i++)
            if (tags[i].type_index >= n_decls) sig_live[tags[i].type_index - n_decls] = 1;
        for (size_t i = 0; i < n_funcs; i++) {
            if (!FUNC_LIVE(i)) continue;
            if (funcs[i].type_index >= n_decls) sig_live[funcs[i].type_index - n_decls] = 1;
            sig_mark_blocks(c, funcs[i].body_first, sig_live);
        }
        sig_remap = xreserve(sigs.n * sizeof *sig_remap);
        uint32_t sidx = 0;
        for (size_t i = 0; i < sigs.n; i++) sig_remap[i] = sig_live[i] ? sidx++ : 0xffffffffu;
        n_live_sigs = sidx;
        c->sig_remap = sig_remap;
        free(sig_live);
    }

    /* Type section (id 1): declared rectypes, then live synthesized func types. */
    Buf types;
    buf_init(&types);
    buf_uleb(&types, n_groups + n_live_sigs);
    for (size_t g = 0; g < n_groups; g++) {
        if (groups[g].is_rec) {
            buf_byte(&types, 0x4e);
            buf_uleb(&types, groups[g].count);
            for (size_t i = groups[g].start; i < groups[g].start + groups[g].count; i++)
                emit_subtype(c, &decls[i], &types);
        } else {
            emit_subtype(c, &decls[groups[g].start], &types);
        }
    }
    for (size_t i = 0; i < sigs.n; i++) {
        if (sig_remap && sig_remap[i] == 0xffffffffu) continue; /* dead signature */
        buf_byte(&types, 0x60);                                 /* func (final, no supertype) */
        buf_uleb(&types, sigs.sigs[i].n_params);
        buf_bytes(&types, sigs.sigs[i].params, sigs.sigs[i].params_len);
        buf_uleb(&types, sigs.sigs[i].n_results);
        buf_bytes(&types, sigs.sigs[i].results, sigs.sigs[i].results_len);
    }

    /* Import section (id 2). */
    Buf importsec;
    buf_init(&importsec);
    buf_uleb(&importsec, n_imports);
    for (size_t i = 0; i < n_imports; i++) {
        buf_uleb(&importsec, imports[i].module_len);
        buf_bytes(&importsec, imports[i].module, imports[i].module_len);
        buf_uleb(&importsec, imports[i].name_len);
        buf_bytes(&importsec, imports[i].name, imports[i].name_len);
        buf_byte(&importsec, 0x00); /* func */
        buf_uleb(&importsec, map_typeidx(c, imports[i].type_index));
    }

    /* Function section (id 3) — live defined functions only. */
    size_t n_live_funcs = 0;
    for (size_t i = 0; i < n_funcs; i++)
        if (FUNC_LIVE(i)) n_live_funcs++;
    Buf funcsec;
    buf_init(&funcsec);
    buf_uleb(&funcsec, n_live_funcs);
    for (size_t i = 0; i < n_funcs; i++)
        if (FUNC_LIVE(i)) buf_uleb(&funcsec, map_typeidx(c, funcs[i].type_index));

    /* Tag section (id 13). */
    Buf tagsec;
    buf_init(&tagsec);
    buf_uleb(&tagsec, n_tags);
    for (size_t i = 0; i < n_tags; i++) {
        buf_byte(&tagsec, 0x00); /* attribute: exception */
        buf_uleb(&tagsec, map_typeidx(c, tags[i].type_index));
    }

    /* Global section (id 6) — live globals only. */
    size_t n_live_globals = 0;
    for (size_t i = 0; i < n_globals; i++)
        if (GLOBAL_LIVE(i)) n_live_globals++;
    Buf globalsec;
    buf_init(&globalsec);
    buf_uleb(&globalsec, n_live_globals);
    FuncCtx no_locals = {0};
    for (size_t i = 0; i < n_globals; i++) {
        if (!GLOBAL_LIVE(i)) continue;
        buf_bytes(&globalsec, globals[i].type, globals[i].type_len);
        buf_byte(&globalsec, globals[i].is_mut ? 1 : 0);
        encode_instr(c, &no_locals, globals[i].init, &globalsec);
        buf_byte(&globalsec, 0x0b); /* end */
    }

    /* Export section (id 7): functions and tags. */
    Buf exports;
    buf_init(&exports);
    size_t n_exports = 0;
    for (size_t i = 0; i < n_funcs; i++)
        if (funcs[i].export_name) n_exports++;
    for (size_t i = 0; i < n_tags; i++)
        if (tags[i].export_name) n_exports++;
    buf_uleb(&exports, n_exports);
    for (size_t i = 0; i < n_funcs; i++) {
        if (!funcs[i].export_name) continue;
        buf_uleb(&exports, funcs[i].export_len);
        buf_bytes(&exports, funcs[i].export_name, funcs[i].export_len);
        buf_byte(&exports, 0x00); /* func */
        buf_uleb(&exports, map_func(c, (uint32_t)(n_imports + i)));
    }
    for (size_t i = 0; i < n_tags; i++) {
        if (!tags[i].export_name) continue;
        buf_uleb(&exports, tags[i].export_len);
        buf_bytes(&exports, tags[i].export_name, tags[i].export_len);
        buf_byte(&exports, 0x04); /* tag */
        buf_uleb(&exports, (uint32_t)i);
    }

    /* Element section (id 9): one declarative segment listing every function
     * used as a ref.func operand (from explicit (elem declare) plus a scan of
     * all bodies and global inits), so those references validate. */
    uint8_t *declared = xreserve(n_all_funcs ? n_all_funcs : 1);
    memset(declared, 0, n_all_funcs ? n_all_funcs : 1);
    for (size_t i = 0; i < n_elems; i++) {
        const SExpr *k = elems[i]->first->next;
        if (!atom_eq(k, "declare")) fail(c, "only (elem declare func ...) is supported");
        k = k->next;
        if (!atom_eq(k, "func")) fail(c, "only (elem declare func ...) is supported");
        for (const SExpr *p = k->next; p; p = p->next)
            declared[resolve_index(c, func_names, n_all_funcs, p, "function")] = 1;
    }
    for (size_t i = 0; i < n_funcs; i++)
        for (const SExpr *k = funcs[i].body_first; k; k = k->next) collect_reffunc(c, k, declared);
    for (size_t i = 0; i < n_globals; i++) collect_reffunc(c, globals[i].init, declared);
    /* A dead function is never ref.func'd by surviving code, so drop it from
     * the declarative segment too. */
    if (dce)
        for (size_t i = 0; i < n_all_funcs; i++)
            if (!reach[i]) declared[i] = 0;
    size_t n_declared = 0;
    for (size_t i = 0; i < n_all_funcs; i++) n_declared += declared[i];
    Buf elemsec;
    buf_init(&elemsec);
    buf_uleb(&elemsec, n_declared ? 1 : 0);
    if (n_declared) {
        buf_byte(&elemsec, 0x03); /* declarative */
        buf_byte(&elemsec, 0x00); /* elemkind: funcref */
        buf_uleb(&elemsec, n_declared);
        for (size_t i = 0; i < n_all_funcs; i++)
            if (declared[i]) buf_uleb(&elemsec, map_func(c, (uint32_t)i));
    }

    /* Data count section (id 12) — required before code when array.new_data
     * (or memory.init / data.drop) references passive segments. */
    Buf datacount;
    buf_init(&datacount);
    if (n_datas) buf_uleb(&datacount, n_datas);

    /* Code section (id 10) — live functions only, matching the func section. */
    Buf code;
    buf_init(&code);
    buf_uleb(&code, n_live_funcs);
    for (size_t i = 0; i < n_funcs; i++)
        if (FUNC_LIVE(i)) encode_code(c, &funcs[i], &code);

    /* Data section (id 11): passive segments. */
    Buf datasec;
    buf_init(&datasec);
    buf_uleb(&datasec, n_datas);
    for (size_t i = 0; i < n_datas; i++) {
        buf_byte(&datasec, 0x01); /* passive */
        buf_uleb(&datasec, datas[i].len);
        buf_bytes(&datasec, datas[i].bytes, datas[i].len);
    }

    /* Assemble the module. Section order follows the spec, with the tag
     * section placed between memory and global, and the data-count section
     * before code. */
    Buf module_buf;
    buf_init(&module_buf);
    static const uint8_t header[8] = {0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00};
    buf_bytes(&module_buf, header, sizeof header);
    put_section(&module_buf, 1, &types);
    put_section(&module_buf, 2, &importsec);
    put_section(&module_buf, 3, &funcsec);
    put_section(&module_buf, 13, &tagsec);
    put_section(&module_buf, 6, &globalsec);
    put_section(&module_buf, 7, &exports);
    put_section(&module_buf, 9, &elemsec);
    if (n_datas) put_section(&module_buf, 12, &datacount);
    put_section(&module_buf, 10, &code);
    put_section(&module_buf, 11, &datasec);

    *out_bytes = module_buf.data;
    *out_len = module_buf.len;

    buf_free(&types);
    buf_free(&importsec);
    buf_free(&funcsec);
    buf_free(&tagsec);
    buf_free(&globalsec);
    buf_free(&exports);
    buf_free(&elemsec);
    buf_free(&datacount);
    buf_free(&code);
    buf_free(&datasec);
    for (size_t i = 0; i < n_funcs; i++) {
        free(funcs[i].sig.params);
        free(funcs[i].sig.results);
        for (size_t j = 0; j < funcs[i].fc.n_locals; j++) free(funcs[i].fc.locals[j].type);
        free(funcs[i].fc.locals);
        free(funcs[i].fc.labels);
    }
    for (size_t i = 0; i < n_imports; i++) {
        free(imports[i].sig.params);
        free(imports[i].sig.results);
    }
    for (size_t i = 0; i < n_tags; i++) {
        free(tags[i].sig.params);
        free(tags[i].sig.results);
    }
    for (size_t i = 0; i < n_globals; i++) free(globals[i].type);
    for (size_t i = 0; i < n_datas; i++) free(datas[i].bytes);
    for (size_t i = 0; i < n_decls; i++) free((void *)decls[i].field_names);
    free(funcs);
    free(globals);
    free(imports);
    free(tags);
    free(datas);
    free(elems);
    free(decls);
    free(groups);
    free(func_names);
    free(global_names);
    free(tag_names);
    free(data_names);
    free(declared);
    free(reach);
    free(func_remap);
    free(global_remap);
    free(sig_remap);
    sig_table_free(&sigs);
    return 0;
#undef PUSH
#undef FUNC_LIVE
#undef GLOBAL_LIVE
}

/* --- public entry point ------------------------------------------------ */

int wat_assemble(const char *wat, size_t wat_len, int dce, uint8_t **out_bytes, size_t *out_len,
                 char *err, size_t errcap) {
    Ctx c;
    memset(&c, 0, sizeof c);
    c.err = err;
    c.errcap = errcap;
    c.src = wat;
    c.len = wat_len;
    if (err && errcap) err[0] = '\0';

    if (setjmp(c.jb)) {
        arena_free(&c.arena);
        return 1;
    }

    SExpr *module = read_sexpr(&c);
    /* Reject trailing junk after the module. */
    skip_trivia(&c);
    if (c.pos < c.len) fail(&c, "unexpected content after top-level form");

    int rc = assemble(&c, module, dce, out_bytes, out_len);
    arena_free(&c.arena);
    return rc;
}
