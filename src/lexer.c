#include "lexer.h"
#include "xalloc.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    Token *items;
    size_t count;
    size_t cap;
} TokVec;

static void push_tok(TokVec *v, Token t) {
    if (v->count == v->cap) {
        v->cap = v->cap ? v->cap * 2 : 16;
        v->items = xrealloc(v->items, v->cap * sizeof(Token));
    }
    v->items[v->count++] = t;
}

typedef struct { const char *kw; TokKind kind; } Keyword;
static const Keyword KEYWORDS[] = {
    { "and",      TOK_KW_AND },
    { "break",    TOK_KW_BREAK },
    { "do",       TOK_KW_DO },
    { "else",     TOK_KW_ELSE },
    { "elseif",   TOK_KW_ELSEIF },
    { "end",      TOK_KW_END },
    { "false",    TOK_KW_FALSE },
    { "for",      TOK_KW_FOR },
    { "function", TOK_KW_FUNCTION },
    { "goto",     TOK_KW_GOTO },
    { "if",       TOK_KW_IF },
    { "in",       TOK_KW_IN },
    { "local",    TOK_KW_LOCAL },
    { "nil",      TOK_KW_NIL },
    { "not",      TOK_KW_NOT },
    { "or",       TOK_KW_OR },
    { "repeat",   TOK_KW_REPEAT },
    { "return",   TOK_KW_RETURN },
    { "then",     TOK_KW_THEN },
    { "true",     TOK_KW_TRUE },
    { "until",    TOK_KW_UNTIL },
    { "while",    TOK_KW_WHILE },
};

static TokKind keyword_or_ident(const char *start, size_t len) {
    for (size_t i = 0; i < sizeof(KEYWORDS) / sizeof(KEYWORDS[0]); i++) {
        if (strlen(KEYWORDS[i].kw) == len && memcmp(KEYWORDS[i].kw, start, len) == 0) {
            return KEYWORDS[i].kind;
        }
    }
    return TOK_IDENT;
}

typedef struct {
    const char *p;
    int line;
    int ok;
    char err[256];
} Lex;

static void lex_error(Lex *L, const char *msg) {
    if (!L->ok) return;
    L->ok = 0;
    snprintf(L->err, sizeof(L->err), "line %d: %s", L->line, msg);
}

/* Decode a quoted string literal. *q is the opening quote char. Advances L->p
 * past the closing quote. Allocates the decoded bytes into *out_buf. */
static int read_string(Lex *L, char q, char **out_buf, size_t *out_len) {
    L->p++; /* skip opening quote */
    /* Upper-bound decoded length by distance-to-closing-quote. Don't stop at
     * '\n': `\z` legally skips over newlines, and an unescaped newline is
     * caught (with a clear error) by the real decode loop below. Stopping at
     * '\n' here under-counted the cap on multi-line `\z` strings and the
     * decoder then overran the buffer. */
    const char *scan = L->p;
    size_t cap = 0;
    while (*scan && *scan != q) {
        if (*scan == '\\' && scan[1]) scan++;
        scan++; cap++;
    }
    size_t len = 0;
    /* Reserve a small extra margin so `\u{...}` can emit up to 4 UTF-8 bytes
     * from a short source form like `\u{0}` (which pre-scan counts as 4). */
    char *buf = xmalloc(cap + 4);
    while (*L->p && *L->p != q) {
        if (*L->p == '\n') { lex_error(L, "newline in string literal"); free(buf); return 0; }
        if (*L->p != '\\') { buf[len++] = *L->p++; continue; }
        L->p++; /* consume backslash */
        char c;
        switch (*L->p) {
            case 'n':  c = '\n'; L->p++; break;
            case 't':  c = '\t'; L->p++; break;
            case 'r':  c = '\r'; L->p++; break;
            case '\\': c = '\\'; L->p++; break;
            case '"':  c = '"';  L->p++; break;
            case '\'': c = '\''; L->p++; break;
            case 'a':  c = '\a'; L->p++; break;
            case 'b':  c = '\b'; L->p++; break;
            case 'f':  c = '\f'; L->p++; break;
            case 'v':  c = '\v'; L->p++; break;

            case 'x': {
                /* `\xHH` — exactly two hex digits. */
                L->p++;
                if (!isxdigit((unsigned char)L->p[0]) || !isxdigit((unsigned char)L->p[1])) {
                    lex_error(L, "hexadecimal digit expected after '\\x'");
                    free(buf); return 0;
                }
                int hi = L->p[0]; int lo = L->p[1];
                int v = ((isdigit(hi) ? hi - '0' : (hi | 32) - 'a' + 10) << 4)
                      |  (isdigit(lo) ? lo - '0' : (lo | 32) - 'a' + 10);
                c = (char)v;
                L->p += 2;
                break;
            }

            case 'z': {
                /* `\z` — skip subsequent whitespace (incl. newlines). */
                L->p++;
                while (isspace((unsigned char)*L->p)) {
                    if (*L->p == '\n') L->line++;
                    L->p++;
                }
                continue;
            }

            case '\n': case '\r': {
                /* `\<line break>` — line continuation. The escape produces
                 * exactly one '\n' regardless of which CR/LF variant ended
                 * the source line (\n, \r, \r\n, \n\r). */
                char first = *L->p;
                L->p++;
                if ((first == '\r' && *L->p == '\n')
                 || (first == '\n' && *L->p == '\r')) L->p++;
                L->line++;
                c = '\n';
                break;
            }

            case 'u': {
                /* `\u{H...}` — variable-length Unicode escape; emits UTF-8. */
                L->p++;
                if (*L->p != '{') { lex_error(L, "'{' expected after '\\u'"); free(buf); return 0; }
                L->p++;
                unsigned long cp = 0;
                int seen = 0;
                while (isxdigit((unsigned char)*L->p)) {
                    int d = *L->p;
                    d = isdigit(d) ? d - '0' : (d | 32) - 'a' + 10;
                    cp = (cp << 4) | (unsigned)d;
                    if (cp > 0x7FFFFFFFu) {
                        lex_error(L, "UTF-8 value too large in '\\u{...}'");
                        free(buf); return 0;
                    }
                    L->p++; seen = 1;
                }
                if (!seen || *L->p != '}') {
                    lex_error(L, "malformed '\\u{...}' escape"); free(buf); return 0;
                }
                L->p++; /* consume '}' */
                /* Encode as UTF-8 (Lua accepts up to 0x7FFFFFFF — beyond Unicode). */
                if (cp < 0x80) {
                    buf[len++] = (char)cp;
                } else if (cp < 0x800) {
                    buf[len++] = (char)(0xC0 | (cp >> 6));
                    buf[len++] = (char)(0x80 | (cp & 0x3F));
                } else if (cp < 0x10000) {
                    buf[len++] = (char)(0xE0 | (cp >> 12));
                    buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    buf[len++] = (char)(0x80 | (cp & 0x3F));
                } else if (cp < 0x200000) {
                    buf[len++] = (char)(0xF0 | (cp >> 18));
                    buf[len++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                    buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    buf[len++] = (char)(0x80 | (cp & 0x3F));
                } else if (cp < 0x4000000) {
                    buf[len++] = (char)(0xF8 | (cp >> 24));
                    buf[len++] = (char)(0x80 | ((cp >> 18) & 0x3F));
                    buf[len++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                    buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    buf[len++] = (char)(0x80 | (cp & 0x3F));
                } else {
                    buf[len++] = (char)(0xFC | (cp >> 30));
                    buf[len++] = (char)(0x80 | ((cp >> 24) & 0x3F));
                    buf[len++] = (char)(0x80 | ((cp >> 18) & 0x3F));
                    buf[len++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                    buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    buf[len++] = (char)(0x80 | (cp & 0x3F));
                }
                continue;
            }

            case '0': case '1': case '2': case '3': case '4':
            case '5': case '6': case '7': case '8': case '9': {
                /* `\ddd` — 1 to 3 decimal digits, value must fit in a byte. */
                int v = 0; int n = 0;
                while (n < 3 && isdigit((unsigned char)*L->p)) {
                    v = v * 10 + (*L->p - '0');
                    L->p++; n++;
                }
                if (v > 255) {
                    lex_error(L, "decimal escape '\\ddd' out of range");
                    free(buf); return 0;
                }
                c = (char)v;
                break;
            }

            default: {
                char msg[64];
                unsigned char bad = (unsigned char)*L->p;
                if (bad >= 0x20 && bad < 0x7f)
                    snprintf(msg, sizeof(msg), "unknown escape sequence '\\%c'", bad);
                else
                    snprintf(msg, sizeof(msg), "unknown escape sequence '\\x%02x'", bad);
                lex_error(L, msg);
                free(buf);
                return 0;
            }
        }
        buf[len++] = c;
    }
    if (*L->p != q) { lex_error(L, "unterminated string"); free(buf); return 0; }
    L->p++; /* closing quote */
    *out_buf = buf;
    *out_len = len;
    return 1;
}

/* Probe whether the current position starts a long-bracket opener
 *   "[=*["
 * — that is, `[` followed by N>=0 `=`s followed by another `[`. Returns
 * the level N on success (advancing L->p past the opener and the
 * optional leading newline). Returns -1 if not a long bracket and
 * leaves L->p unchanged. */
static int try_open_long_bracket(Lex *L) {
    if (L->p[0] != '[') return -1;
    int level = 0;
    while (L->p[1 + level] == '=') level++;
    if (L->p[1 + level] != '[') return -1;
    L->p += 2 + level;                       /* skip "[=...=[" */
    if (*L->p == '\n') { L->line++; L->p++; }
    return level;
}

/* Read the body of a long bracket until the matching close "]=...=]".
 * Sets *out_buf / *out_len to the body bytes (caller frees). Returns 1
 * on success, 0 if EOF was hit before the close. */
static int read_long_body(Lex *L, int level, char **out_buf, size_t *out_len) {
    const char *start = L->p;
    while (*L->p) {
        if (L->p[0] == ']') {
            int n = 0;
            while (L->p[1 + n] == '=') n++;
            if (n == level && L->p[1 + n] == ']') {
                size_t len = (size_t)(L->p - start);
                char *buf = xmalloc(len ? len : 1);
                if (len) memcpy(buf, start, len);
                *out_buf = buf; *out_len = len;
                L->p += 2 + level;           /* skip "]=...=]" */
                return 1;
            }
        }
        if (*L->p == '\n') L->line++;
        L->p++;
    }
    return 0;
}

/* --[=*[ ... ]=*] long comment.  Caller already consumed "--" and the
 * opener has just been recognized by try_open_long_bracket. */
static void skip_long_comment(Lex *L, int level) {
    char *buf = NULL; size_t len = 0;
    if (!read_long_body(L, level, &buf, &len)) {
        lex_error(L, "unterminated long comment");
        return;
    }
    free(buf);
}

TokenList lex(const char *source) {
    TokVec v = {0};
    Lex L = { .p = source, .line = 1, .ok = 1 };

    /* Stock Lua silently skips a leading line that starts with '#'
     * — used for both Unix shebangs (`#!/usr/bin/env lua`) and the
     * occasional "special comment on first line" marker in test files.
     * The newline itself is left in place so line numbers stay accurate. */
    if (*L.p == '#') {
        while (*L.p && *L.p != '\n') L.p++;
    }

    while (*L.p && L.ok) {
        char c = *L.p;
        if (c == '\n') { L.line++; L.p++; continue; }
        if (isspace((unsigned char)c)) { L.p++; continue; }

        /* comments */
        if (c == '-' && L.p[1] == '-') {
            L.p += 2;
            if (L.p[0] == '[') {
                int level = try_open_long_bracket(&L);
                if (level >= 0) { skip_long_comment(&L, level); continue; }
            }
            while (*L.p && *L.p != '\n') L.p++;
            continue;
        }

        Token t = { .start = L.p, .line = L.line };

        /* numbers (int or float, decimal or 0x-hex) */
        if (isdigit((unsigned char)c)) {
            const char *s = L.p;
            int is_float = 0;
            int is_hex = 0;
            /* Hex literal: 0x... or 0X... */
            if (c == '0' && (L.p[1] == 'x' || L.p[1] == 'X')) {
                is_hex = 1;
                L.p += 2;
                while (isxdigit((unsigned char)*L.p)) L.p++;
                if (*L.p == '.') {
                    is_float = 1;
                    L.p++;
                    while (isxdigit((unsigned char)*L.p)) L.p++;
                }
                if (*L.p == 'p' || *L.p == 'P') {
                    is_float = 1;
                    L.p++;
                    if (*L.p == '+' || *L.p == '-') L.p++;
                    while (isdigit((unsigned char)*L.p)) L.p++;
                }
            } else {
                while (isdigit((unsigned char)*L.p)) L.p++;
                if (*L.p == '.') { is_float = 1; L.p++; while (isdigit((unsigned char)*L.p)) L.p++; }
                if (*L.p == 'e' || *L.p == 'E') {
                    is_float = 1;
                    L.p++;
                    if (*L.p == '+' || *L.p == '-') L.p++;
                    while (isdigit((unsigned char)*L.p)) L.p++;
                }
            }
            t.len = (size_t)(L.p - s);
            char tmp[64];
            size_t n = t.len < 63 ? t.len : 63;
            memcpy(tmp, s, n); tmp[n] = '\0';
            if (is_float) {
                t.kind = TOK_FLOAT;
                /* strtod handles both decimal and C99 hex floats (0x1.8p3). */
                t.f_val = strtod(tmp, NULL);
            } else if (is_hex) {
                /* Hex int literals wrap mod 2^64 per Lua 5.5: even a
                 * 26-digit literal denotes an integer (its low 64 bits).
                 * strtoll saturates at LLONG_MAX, so accumulate digits
                 * ourselves in a u64 and reinterpret. */
                t.kind = TOK_INT;
                unsigned long long acc = 0;
                for (size_t k = 2; k < n; k++) {  /* skip "0x" prefix */
                    unsigned c2 = (unsigned char)tmp[k];
                    unsigned d = c2 <= '9' ? c2 - '0'
                               : c2 <= 'F' ? c2 - 'A' + 10
                               :             c2 - 'a' + 10;
                    acc = (acc << 4) | d;
                }
                t.i_val = (long long)acc;
            } else {
                t.kind = TOK_INT;
                /* Lua has no octal integer syntax — a leading zero is just
                 * a decimal digit. */
                t.i_val = strtoll(tmp, NULL, 10);
            }
            push_tok(&v, t);
            continue;
        }

        /* identifiers / keywords */
        if (isalpha((unsigned char)c) || c == '_') {
            const char *s = L.p;
            while (isalnum((unsigned char)*L.p) || *L.p == '_') L.p++;
            t.len = (size_t)(L.p - s);
            t.kind = keyword_or_ident(s, t.len);
            push_tok(&v, t);
            continue;
        }

        /* strings */
        if (c == '"' || c == '\'') {
            if (!read_string(&L, c, &t.str_buf, &t.str_len)) break;
            t.kind = TOK_STRING;
            t.len = (size_t)(L.p - t.start);
            push_tok(&v, t);
            continue;
        }

        /* operators / punctuation */
        #define ONE(kind_)  do { t.kind = (kind_); t.len = 1; L.p++; } while (0)
        #define TWO(kind_)  do { t.kind = (kind_); t.len = 2; L.p += 2; } while (0)
        #define THREE(kind_) do { t.kind = (kind_); t.len = 3; L.p += 3; } while (0)

        switch (c) {
            case '(': ONE(TOK_LPAREN); break;
            case ')': ONE(TOK_RPAREN); break;
            case '{': ONE(TOK_LBRACE); break;
            case '}': ONE(TOK_RBRACE); break;
            case '[': {
                int level = try_open_long_bracket(&L);
                if (level < 0) { ONE(TOK_LBRACKET); break; }
                /* Long-bracket string [=*[ ... ]=*]. Body bytes verbatim
                 * (no escape processing), leading newline already stripped
                 * by try_open_long_bracket. */
                if (!read_long_body(&L, level, &t.str_buf, &t.str_len)) {
                    lex_error(&L, "unterminated long string");
                    t.kind = TOK_ERROR; t.len = 0;
                    break;
                }
                t.kind = TOK_STRING;
                t.len = (size_t)(L.p - t.start);
                break;
            }
            case ']': ONE(TOK_RBRACKET); break;
            case ',': ONE(TOK_COMMA); break;
            case ';': ONE(TOK_SEMI); break;
            case '+': ONE(TOK_PLUS); break;
            case '-': ONE(TOK_MINUS); break;
            case '*': ONE(TOK_STAR); break;
            case '%': ONE(TOK_PERCENT); break;
            case '^': ONE(TOK_CARET); break;
            case '#': ONE(TOK_HASH); break;
            case '&': ONE(TOK_AMP); break;
            case '|': ONE(TOK_PIPE); break;
            case '/': if (L.p[1] == '/') TWO(TOK_DSLASH); else ONE(TOK_SLASH); break;
            case ':': if (L.p[1] == ':') TWO(TOK_DBLCOLON); else ONE(TOK_COLON); break;
            case '=': if (L.p[1] == '=') TWO(TOK_EQ);      else ONE(TOK_ASSIGN); break;
            case '~': if (L.p[1] == '=') TWO(TOK_NEQ);     else ONE(TOK_TILDE); break;
            case '<': if (L.p[1] == '=') TWO(TOK_LE);
                      else if (L.p[1] == '<') TWO(TOK_SHL);
                      else ONE(TOK_LT); break;
            case '>': if (L.p[1] == '=') TWO(TOK_GE);
                      else if (L.p[1] == '>') TWO(TOK_SHR);
                      else ONE(TOK_GT); break;
            case '.':
                if (L.p[1] == '.' && L.p[2] == '.') THREE(TOK_ELLIPSIS);
                else if (L.p[1] == '.') TWO(TOK_CONCAT);
                else if (isdigit((unsigned char)L.p[1])) {
                    /* .5 style float */
                    const char *s = L.p;
                    L.p++; /* . */
                    while (isdigit((unsigned char)*L.p)) L.p++;
                    if (*L.p == 'e' || *L.p == 'E') {
                        L.p++;
                        if (*L.p == '+' || *L.p == '-') L.p++;
                        while (isdigit((unsigned char)*L.p)) L.p++;
                    }
                    char tmp[64]; size_t n = (size_t)(L.p - s);
                    if (n >= 63) n = 63;
                    memcpy(tmp, s, n); tmp[n] = '\0';
                    t.kind = TOK_FLOAT;
                    t.f_val = strtod(tmp, NULL);
                    t.len = (size_t)(L.p - s);
                } else ONE(TOK_DOT);
                break;
            default:
                lex_error(&L, "unexpected character");
                t.kind = TOK_ERROR; t.len = 1; L.p++;
                break;
        }
        if (L.ok) push_tok(&v, t);

        #undef ONE
        #undef TWO
        #undef THREE
    }

    Token eof = { .kind = TOK_EOF, .start = L.p, .len = 0, .line = L.line };
    push_tok(&v, eof);

    TokenList r = { .items = v.items, .count = v.count, .ok = L.ok };
    if (!L.ok) memcpy(r.err, L.err, sizeof(r.err));
    return r;
}

void tokenlist_free(TokenList *t) {
    for (size_t i = 0; i < t->count; i++) {
        if (t->items[i].kind == TOK_STRING) free(t->items[i].str_buf);
    }
    free(t->items);
    t->items = NULL;
    t->count = 0;
}

const char *tok_kind_name(TokKind k) {
    switch (k) {
        case TOK_EOF: return "EOF";
        case TOK_ERROR: return "ERROR";
        case TOK_IDENT: return "IDENT";
        case TOK_INT: return "INT";
        case TOK_FLOAT: return "FLOAT";
        case TOK_STRING: return "STRING";
        case TOK_LPAREN: return "(";
        case TOK_RPAREN: return ")";
        case TOK_LBRACE: return "{";
        case TOK_RBRACE: return "}";
        case TOK_LBRACKET: return "[";
        case TOK_RBRACKET: return "]";
        case TOK_COMMA: return ",";
        case TOK_SEMI: return ";";
        case TOK_COLON: return ":";
        case TOK_DBLCOLON: return "::";
        case TOK_DOT: return ".";
        case TOK_CONCAT: return "..";
        case TOK_ELLIPSIS: return "...";
        case TOK_ASSIGN: return "=";
        case TOK_PLUS: return "+";
        case TOK_MINUS: return "-";
        case TOK_STAR: return "*";
        case TOK_SLASH: return "/";
        case TOK_DSLASH: return "//";
        case TOK_PERCENT: return "%";
        case TOK_CARET: return "^";
        case TOK_HASH: return "#";
        case TOK_EQ: return "==";
        case TOK_NEQ: return "~=";
        case TOK_LT: return "<";
        case TOK_LE: return "<=";
        case TOK_GT: return ">";
        case TOK_GE: return ">=";
        case TOK_AMP: return "&";
        case TOK_PIPE: return "|";
        case TOK_TILDE: return "~";
        case TOK_SHL: return "<<";
        case TOK_SHR: return ">>";
        case TOK_KW_AND: return "and";
        case TOK_KW_BREAK: return "break";
        case TOK_KW_DO: return "do";
        case TOK_KW_ELSE: return "else";
        case TOK_KW_ELSEIF: return "elseif";
        case TOK_KW_END: return "end";
        case TOK_KW_FALSE: return "false";
        case TOK_KW_FOR: return "for";
        case TOK_KW_FUNCTION: return "function";
        case TOK_KW_GOTO: return "goto";
        case TOK_KW_IF: return "if";
        case TOK_KW_IN: return "in";
        case TOK_KW_LOCAL: return "local";
        case TOK_KW_NIL: return "nil";
        case TOK_KW_NOT: return "not";
        case TOK_KW_OR: return "or";
        case TOK_KW_REPEAT: return "repeat";
        case TOK_KW_RETURN: return "return";
        case TOK_KW_THEN: return "then";
        case TOK_KW_TRUE: return "true";
        case TOK_KW_UNTIL: return "until";
        case TOK_KW_WHILE: return "while";
    }
    return "?";
}
