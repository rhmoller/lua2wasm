/* Freestanding <ctype.h> — ASCII-only, the subset the lexer uses.
 * Implemented inline; the lexer only ever feeds these unsigned char / EOF. */
#ifndef _CTYPE_H
#define _CTYPE_H

static inline int isdigit(int c) { return c >= '0' && c <= '9'; }
static inline int isxdigit(int c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
static inline int isspace(int c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}
static inline int isalpha(int c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
static inline int isalnum(int c) { return isalpha(c) || isdigit(c); }

#endif /* _CTYPE_H */
