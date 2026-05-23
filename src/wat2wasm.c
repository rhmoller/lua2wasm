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
    /* list: children as a singly linked list */
    struct SExpr *first, *last;
    size_t n_kids;
    /* sibling link within the parent's child list */
    struct SExpr *next;
} SExpr;

/* --- assembler context ------------------------------------------------- */

typedef struct {
    jmp_buf jb;
    char *err;
    size_t errcap;
    Arena arena;
    /* lexer cursor */
    const char *src;
    size_t len, pos;
} Ctx;

static void fail(Ctx *c, const char *fmt, ...) {
    if (c->err && c->errcap) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(c->err, c->errcap, fmt, ap);
        va_end(ap);
    }
    longjmp(c->jb, 1);
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
    char ch = c->src[c->pos];
    if (ch == ')') fail(c, "unexpected ')'");
    if (ch == '(') {
        c->pos++;
        SExpr *list = new_node(c);
        list->is_list = 1;
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

/* --- value types ------------------------------------------------------- */

/* Numeric value type byte, or 0 if `s` isn't one we handle yet. */
static uint8_t numtype_byte(const char *s) {
    if (strcmp(s, "i32") == 0) return 0x7f;
    if (strcmp(s, "i64") == 0) return 0x7e;
    if (strcmp(s, "f32") == 0) return 0x7d;
    if (strcmp(s, "f64") == 0) return 0x7c;
    return 0;
}

static uint8_t valtype_byte(Ctx *c, const SExpr *n) {
    if (!is_atom(n)) fail(c, "expected a value type");
    uint8_t b = numtype_byte(n->atom);
    if (!b) fail(c, "unsupported value type '%s'", n->atom);
    return b;
}

/* --- function signatures (type section) -------------------------------- */

typedef struct {
    uint8_t *params;
    size_t n_params;
    uint8_t *results;
    size_t n_results;
} FuncSig;

typedef struct {
    FuncSig *sigs;
    size_t n, cap;
} SigTable;

static int sig_eq(const FuncSig *a, const FuncSig *b) {
    if (a->n_params != b->n_params || a->n_results != b->n_results) return 0;
    return memcmp(a->params, b->params, a->n_params) == 0 &&
           memcmp(a->results, b->results, a->n_results) == 0;
}

/* Intern a signature, returning its type index. */
static uint32_t sig_intern(SigTable *t, const FuncSig *s) {
    for (size_t i = 0; i < t->n; i++)
        if (sig_eq(&t->sigs[i], s)) return (uint32_t)i;
    if (t->n == t->cap) {
        t->cap = t->cap ? t->cap * 2 : 8;
        t->sigs = xgrow(t->sigs, t->cap * sizeof *t->sigs);
    }
    t->sigs[t->n] = *s;
    return (uint32_t)t->n++;
}

/* --- per-function state ------------------------------------------------ */

typedef struct {
    const char *name; /* $id, or NULL */
    uint8_t type;
} Local;

typedef struct {
    Local *locals; /* params then declared locals */
    size_t n_locals, cap_locals;
    size_t n_params;
} FuncCtx;

static void fc_add_local(FuncCtx *f, const char *name, uint8_t type) {
    if (f->n_locals == f->cap_locals) {
        f->cap_locals = f->cap_locals ? f->cap_locals * 2 : 8;
        f->locals = xgrow(f->locals, f->cap_locals * sizeof *f->locals);
    }
    f->locals[f->n_locals].name = name;
    f->locals[f->n_locals].type = type;
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

/* --- instruction encoding ---------------------------------------------- */

static void encode_instr(Ctx *c, FuncCtx *f, const SExpr *n, Buf *out);

/* Encode every operand child in [from .. end). */
static void encode_operands(Ctx *c, FuncCtx *f, const SExpr *from, Buf *out) {
    for (const SExpr *k = from; k; k = k->next) encode_instr(c, f, k, out);
}

static void encode_instr(Ctx *c, FuncCtx *f, const SExpr *n, Buf *out) {
    const char *op = head(n);
    if (!op) fail(c, "expected an instruction");
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

    /* Zero-immediate ops: encode folded operands, then the opcode. */
    const OpEntry *e = find_op(op);
    if (e) {
        encode_operands(c, f, arg1, out);
        buf_byte(out, e->op);
        return;
    }

    fail(c, "unsupported instruction '%s'", op);
}

/* --- function parsing -------------------------------------------------- */

typedef struct {
    const char *name;        /* $id or NULL */
    const char *export_name; /* decoded export string or NULL */
    size_t export_len;
    uint32_t type_index;
    FuncSig sig;
    FuncCtx fc;
    const SExpr *body_first; /* first body instruction node */
} Func;

/* Collect a (param ...) / (local ...) group into the function context and,
 * for params, the signature param list. */
static void collect_locals(Ctx *c, const SExpr *grp, FuncCtx *f, uint8_t **vec,
                           size_t *n, size_t *cap, int is_param) {
    const SExpr *k = grp->first->next; /* skip head keyword */
    if (k && is_atom(k) && k->atom[0] == '$') {
        /* (param $id valtype) — exactly one named type */
        const SExpr *tn = k->next;
        uint8_t b = valtype_byte(c, tn);
        if (vec) {
            if (*n == *cap) {
                *cap = *cap ? *cap * 2 : 4;
                *vec = xgrow(*vec, *cap);
            }
            (*vec)[(*n)++] = b;
        }
        fc_add_local(f, k->atom, b);
        if (is_param) f->n_params++;
        return;
    }
    for (; k; k = k->next) {
        uint8_t b = valtype_byte(c, k);
        if (vec) {
            if (*n == *cap) {
                *cap = *cap ? *cap * 2 : 4;
                *vec = xgrow(*vec, *cap);
            }
            (*vec)[(*n)++] = b;
        }
        fc_add_local(f, NULL, b);
        if (is_param) f->n_params++;
    }
}

static void parse_func(Ctx *c, const SExpr *fn, Func *out) {
    memset(out, 0, sizeof *out);
    size_t pcap = 0, rcap = 0;
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
        if (!body_started && h && strcmp(h, "param") == 0) {
            collect_locals(c, k, &out->fc, &out->sig.params, &out->sig.n_params, &pcap, 1);
            continue;
        }
        if (!body_started && h && strcmp(h, "result") == 0) {
            for (const SExpr *r = k->first->next; r; r = r->next) {
                if (out->sig.n_results == rcap) {
                    rcap = rcap ? rcap * 2 : 4;
                    out->sig.results = xgrow(out->sig.results, rcap);
                }
                out->sig.results[out->sig.n_results++] = valtype_byte(c, r);
            }
            continue;
        }
        if (!body_started && h && strcmp(h, "local") == 0) {
            collect_locals(c, k, &out->fc, NULL, NULL, NULL, 0);
            continue;
        }
        if (!body_started && h && strcmp(h, "type") == 0) {
            fail(c, "(type ...) references are not supported yet");
        }
        /* First non-meta node: the body begins here. */
        body_started = 1;
        if (!out->body_first) out->body_first = k;
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
        while (j < fn->fc.n_locals && fn->fc.locals[j].type == fn->fc.locals[i].type) j++;
        buf_uleb(&locals, j - i);
        buf_byte(&locals, fn->fc.locals[i].type);
        groups++;
        i = j;
    }

    for (const SExpr *k = fn->body_first; k; k = k->next) encode_instr(c, &fn->fc, k, &body);
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

/* --- top-level assembly ------------------------------------------------ */

static int assemble(Ctx *c, const SExpr *module, uint8_t **out_bytes, size_t *out_len) {
    if (!module || !atom_eq(module->first, "module"))
        fail(c, "expected a top-level (module ...)");

    /* Collect functions. */
    Func *funcs = NULL;
    size_t n_funcs = 0, cap_funcs = 0;
    SigTable sigs = {0};

    for (const SExpr *k = module->first->next; k; k = k->next) {
        const char *h = head(k);
        if (h && strcmp(h, "func") == 0) {
            if (n_funcs == cap_funcs) {
                cap_funcs = cap_funcs ? cap_funcs * 2 : 8;
                funcs = xgrow(funcs, cap_funcs * sizeof *funcs);
            }
            parse_func(c, k, &funcs[n_funcs]);
            funcs[n_funcs].type_index = sig_intern(&sigs, &funcs[n_funcs].sig);
            n_funcs++;
        } else if (h) {
            fail(c, "unsupported module field '%s'", h);
        } else {
            fail(c, "unsupported module field");
        }
    }

    /* Type section (id 1). */
    Buf types;
    buf_init(&types);
    buf_uleb(&types, sigs.n);
    for (size_t i = 0; i < sigs.n; i++) {
        buf_byte(&types, 0x60); /* func */
        buf_uleb(&types, sigs.sigs[i].n_params);
        buf_bytes(&types, sigs.sigs[i].params, sigs.sigs[i].n_params);
        buf_uleb(&types, sigs.sigs[i].n_results);
        buf_bytes(&types, sigs.sigs[i].results, sigs.sigs[i].n_results);
    }

    /* Function section (id 3). */
    Buf funcsec;
    buf_init(&funcsec);
    buf_uleb(&funcsec, n_funcs);
    for (size_t i = 0; i < n_funcs; i++) buf_uleb(&funcsec, funcs[i].type_index);

    /* Export section (id 7). */
    Buf exports;
    buf_init(&exports);
    size_t n_exports = 0;
    for (size_t i = 0; i < n_funcs; i++)
        if (funcs[i].export_name) n_exports++;
    buf_uleb(&exports, n_exports);
    for (size_t i = 0; i < n_funcs; i++) {
        if (!funcs[i].export_name) continue;
        buf_uleb(&exports, funcs[i].export_len);
        buf_bytes(&exports, funcs[i].export_name, funcs[i].export_len);
        buf_byte(&exports, 0x00); /* func */
        buf_uleb(&exports, (uint32_t)i);
    }

    /* Code section (id 10). */
    Buf code;
    buf_init(&code);
    buf_uleb(&code, n_funcs);
    for (size_t i = 0; i < n_funcs; i++) encode_code(c, &funcs[i], &code);

    /* Assemble the module. */
    Buf module_buf;
    buf_init(&module_buf);
    static const uint8_t header[8] = {0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00};
    buf_bytes(&module_buf, header, sizeof header);
    put_section(&module_buf, 1, &types);
    put_section(&module_buf, 3, &funcsec);
    put_section(&module_buf, 7, &exports);
    put_section(&module_buf, 10, &code);

    *out_bytes = module_buf.data;
    *out_len = module_buf.len;

    buf_free(&types);
    buf_free(&funcsec);
    buf_free(&exports);
    buf_free(&code);
    for (size_t i = 0; i < n_funcs; i++) {
        free(funcs[i].sig.params);
        free(funcs[i].sig.results);
        free(funcs[i].fc.locals);
    }
    free(funcs);
    /* sigs.sigs entries alias the Func-owned param/result vecs (freed above),
     * so only the table array itself is released here. */
    free(sigs.sigs);
    return 0;
}

/* --- public entry point ------------------------------------------------ */

int wat_assemble(const char *wat, size_t wat_len, uint8_t **out_bytes, size_t *out_len,
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

    int rc = assemble(&c, module, out_bytes, out_len);
    arena_free(&c.arena);
    return rc;
}
