#ifndef LUA2WASM_AST_H
#define LUA2WASM_AST_H

#include <stddef.h>
#include <stdint.h>

/* ---------- expressions ---------- */
typedef enum {
    EXPR_NIL,
    EXPR_TRUE,
    EXPR_FALSE,
    EXPR_INT,
    EXPR_FLOAT,
    EXPR_STRING,
    EXPR_VAR,           /* local var reference; resolved to local_idx */
    EXPR_CALL,
    EXPR_BINOP,
    EXPR_UNOP,
} ExprKind;

typedef enum {
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_FDIV, BIN_MOD, BIN_POW,
    BIN_CONCAT,
    BIN_EQ, BIN_NEQ, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
    BIN_AND, BIN_OR,
} BinOp;

typedef enum {
    UN_NEG,     /* -x */
    UN_NOT,     /* not x */
    UN_LEN,     /* #x */
} UnOp;

typedef struct Expr Expr;

struct Expr {
    ExprKind kind;
    int line;
    union {
        int64_t i_val;                  /* EXPR_INT */
        double f_val;                   /* EXPR_FLOAT */
        struct {                        /* EXPR_STRING */
            const char *bytes;          /* owned by lexer; valid for lifetime of token list */
            size_t len;
        } s;
        struct {                        /* EXPR_VAR */
            const char *name;
            size_t name_len;
            int local_idx;              /* -1 until resolved; -2 = builtin (print) */
        } var;
        struct {                        /* EXPR_CALL */
            Expr *callee;
            Expr **args;
            size_t nargs;
        } call;
        struct {                        /* EXPR_BINOP */
            BinOp op;
            Expr *lhs;
            Expr *rhs;
        } binop;
        struct {                        /* EXPR_UNOP */
            UnOp op;
            Expr *operand;
        } unop;
    } as;
};

/* ---------- statements ---------- */
typedef enum {
    STMT_LOCAL,         /* local name = expr (single binding for v2) */
    STMT_ASSIGN,        /* name = expr (target must be a local) */
    STMT_EXPR,          /* expression statement (call) */
    STMT_IF,            /* if cond then ... [elseif ...] [else ...] end */
    STMT_WHILE,         /* while cond do ... end */
    STMT_DO,            /* do ... end */
    STMT_RETURN,        /* return [exprs] -- v2 supports return with no value */
} StmtKind;

typedef struct Stmt Stmt;
typedef struct Block Block;

struct Block {
    Stmt **items;
    size_t count;
};

/* if/elseif chain: array of (cond, body) plus optional else body. */
typedef struct {
    Expr *cond;
    Block body;
} IfArm;

struct Stmt {
    StmtKind kind;
    int line;
    union {
        struct {                        /* STMT_LOCAL */
            const char *name;
            size_t name_len;
            Expr *init;                 /* may be NULL */
            int local_idx;              /* filled in during scope resolve */
        } local;
        struct {                        /* STMT_ASSIGN */
            const char *name;
            size_t name_len;
            Expr *value;
            int local_idx;              /* resolved */
        } assign;
        struct {                        /* STMT_EXPR */
            Expr *expr;
        } expr_stmt;
        struct {                        /* STMT_IF */
            IfArm *arms;                /* arms[0] is `if`, rest are `elseif` */
            size_t narms;
            int has_else;
            Block else_body;
        } if_stmt;
        struct {                        /* STMT_WHILE */
            Expr *cond;
            Block body;
        } while_stmt;
        struct {                        /* STMT_DO */
            Block body;
        } do_stmt;
    } as;
};

/* ---------- node pool ---------- */
typedef struct {
    char *buf;
    size_t used;
    size_t cap;
} NodePool;

void node_pool_init(NodePool *p);
void node_pool_free(NodePool *p);
void *node_pool_alloc(NodePool *p, size_t bytes);

Expr *expr_new(NodePool *p, ExprKind k, int line);
Stmt *stmt_new(NodePool *p, StmtKind k, int line);

#endif
