#ifndef LUA2WASM_LEXER_H
#define LUA2WASM_LEXER_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    TOK_EOF,
    TOK_ERROR,

    /* literals */
    TOK_IDENT,
    TOK_INT,    /* integer literal */
    TOK_FLOAT,  /* float literal */
    TOK_STRING, /* "..." or '...' - decoded into Token.str_buf */

    /* punctuation */
    TOK_LPAREN,   /* ( */
    TOK_RPAREN,   /* ) */
    TOK_LBRACE,   /* { */
    TOK_RBRACE,   /* } */
    TOK_LBRACKET, /* [ */
    TOK_RBRACKET, /* ] */
    TOK_COMMA,    /* , */
    TOK_SEMI,     /* ; */
    TOK_COLON,    /* : */
    TOK_DBLCOLON, /* :: */
    TOK_DOT,      /* .  */
    TOK_CONCAT,   /* .. */
    TOK_ELLIPSIS, /* ... */
    TOK_ASSIGN,   /* = */

    /* arithmetic */
    TOK_PLUS,    /* + */
    TOK_MINUS,   /* - */
    TOK_STAR,    /* * */
    TOK_SLASH,   /* / */
    TOK_DSLASH,  /* // floor div */
    TOK_PERCENT, /* % */
    TOK_CARET,   /* ^ */
    TOK_HASH,    /* # length */

    /* comparison */
    TOK_EQ,  /* == */
    TOK_NEQ, /* ~= */
    TOK_LT,  /* < */
    TOK_LE,  /* <= */
    TOK_GT,  /* > */
    TOK_GE,  /* >= */

    /* bitwise (lexed; codegen later) */
    TOK_AMP,   /* & */
    TOK_PIPE,  /* | */
    TOK_TILDE, /* ~ */
    TOK_SHL,   /* << */
    TOK_SHR,   /* >> */

    /* keywords */
    TOK_KW_AND,
    TOK_KW_BREAK,
    TOK_KW_DO,
    TOK_KW_ELSE,
    TOK_KW_ELSEIF,
    TOK_KW_END,
    TOK_KW_FALSE,
    TOK_KW_FOR,
    TOK_KW_FUNCTION,
    TOK_KW_GOTO,
    TOK_KW_IF,
    TOK_KW_IN,
    TOK_KW_LOCAL,
    TOK_KW_NIL,
    TOK_KW_NOT,
    TOK_KW_OR,
    TOK_KW_REPEAT,
    TOK_KW_RETURN,
    TOK_KW_THEN,
    TOK_KW_TRUE,
    TOK_KW_UNTIL,
    TOK_KW_WHILE,
} TokKind;

typedef struct {
    TokKind kind;
    const char *start; /* points into source for IDENT and raw spans */
    size_t len;        /* length of span in source */
    int line;
    /* literal payload */
    int64_t i_val; /* TOK_INT */
    double f_val;  /* TOK_FLOAT */
    char *str_buf; /* TOK_STRING: decoded bytes (owned), str_len long */
    size_t str_len;
} Token;

typedef struct {
    Token *items;
    size_t count;
    /* If a lexical error occurred, ok==0 and err holds the message. */
    int ok;
    char err[256];
} TokenList;

TokenList lex(const char *source);
void tokenlist_free(TokenList *t);
const char *tok_kind_name(TokKind k);

#endif
