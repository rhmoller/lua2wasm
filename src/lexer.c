#include "lexer.h"
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
        v->items = realloc(v->items, v->cap * sizeof(Token));
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
    size_t cap = 16, len = 0;
    char *buf = malloc(cap);
    while (*L->p && *L->p != q) {
        if (*L->p == '\n') { lex_error(L, "newline in string literal"); free(buf); return 0; }
        char c;
        if (*L->p == '\\') {
            L->p++;
            switch (*L->p) {
                case 'n':  c = '\n'; break;
                case 't':  c = '\t'; break;
                case 'r':  c = '\r'; break;
                case '\\': c = '\\'; break;
                case '"':  c = '"';  break;
                case '\'': c = '\''; break;
                case '0':  c = '\0'; break;
                case 'a':  c = '\a'; break;
                case 'b':  c = '\b'; break;
                case 'f':  c = '\f'; break;
                case 'v':  c = '\v'; break;
                default:
                    lex_error(L, "unknown escape sequence");
                    free(buf);
                    return 0;
            }
            L->p++;
        } else {
            c = *L->p++;
        }
        if (len + 1 > cap) { cap *= 2; buf = realloc(buf, cap); }
        buf[len++] = c;
    }
    if (*L->p != q) { lex_error(L, "unterminated string"); free(buf); return 0; }
    L->p++; /* closing quote */
    *out_buf = buf;
    *out_len = len;
    return 1;
}

/* --[[ ... ]] long comment.  Caller already consumed "--". */
static void skip_long_comment(Lex *L) {
    /* p currently at first '[' */
    L->p += 2; /* skip [[ */
    while (*L->p) {
        if (L->p[0] == ']' && L->p[1] == ']') { L->p += 2; return; }
        if (*L->p == '\n') L->line++;
        L->p++;
    }
    lex_error(L, "unterminated long comment");
}

TokenList lex(const char *source) {
    TokVec v = {0};
    Lex L = { .p = source, .line = 1, .ok = 1 };

    while (*L.p && L.ok) {
        char c = *L.p;
        if (c == '\n') { L.line++; L.p++; continue; }
        if (isspace((unsigned char)c)) { L.p++; continue; }

        /* comments */
        if (c == '-' && L.p[1] == '-') {
            L.p += 2;
            if (L.p[0] == '[' && L.p[1] == '[') { skip_long_comment(&L); continue; }
            while (*L.p && *L.p != '\n') L.p++;
            continue;
        }

        Token t = { .start = L.p, .line = L.line };

        /* numbers (int or float) */
        if (isdigit((unsigned char)c)) {
            const char *s = L.p;
            int is_float = 0;
            while (isdigit((unsigned char)*L.p)) L.p++;
            if (*L.p == '.') { is_float = 1; L.p++; while (isdigit((unsigned char)*L.p)) L.p++; }
            if (*L.p == 'e' || *L.p == 'E') {
                is_float = 1;
                L.p++;
                if (*L.p == '+' || *L.p == '-') L.p++;
                while (isdigit((unsigned char)*L.p)) L.p++;
            }
            t.len = (size_t)(L.p - s);
            char tmp[64];
            size_t n = t.len < 63 ? t.len : 63;
            memcpy(tmp, s, n); tmp[n] = '\0';
            if (is_float) {
                t.kind = TOK_FLOAT;
                t.f_val = strtod(tmp, NULL);
            } else {
                t.kind = TOK_INT;
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
            case '[':
                if (L.p[1] == '[') {
                    /* Long-bracket string [[ ... ]] (level 0 only; no [=[…]=]) */
                    L.p += 2; /* skip [[ */
                    /* Per Lua: a leading newline immediately after the open
                     * bracket is stripped. */
                    if (*L.p == '\n') { L.line++; L.p++; }
                    const char *start = L.p;
                    while (*L.p && !(L.p[0] == ']' && L.p[1] == ']')) {
                        if (*L.p == '\n') L.line++;
                        L.p++;
                    }
                    if (!*L.p) { lex_error(&L, "unterminated long string"); t.kind = TOK_ERROR; t.len = 0; break; }
                    size_t len = (size_t)(L.p - start);
                    t.kind = TOK_STRING;
                    t.str_buf = malloc(len ? len : 1);
                    if (len) memcpy(t.str_buf, start, len);
                    t.str_len = len;
                    L.p += 2; /* skip ]] */
                    t.len = (size_t)(L.p - t.start);
                } else {
                    ONE(TOK_LBRACKET);
                }
                break;
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
