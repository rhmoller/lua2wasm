#ifndef LUA2WASM_AST_H
#define LUA2WASM_AST_H

#include <stddef.h>
#include <stdint.h>

/* ---------- forward decls ---------- */
typedef struct Expr Expr;
typedef struct Stmt Stmt;
typedef struct LuaFunc LuaFunc;
typedef struct Block Block;

/* ---------- upvalue references ----------
 * Each LuaFunc has a list of upvalues it captures from its enclosing function.
 * Each upvalue is sourced either from the enclosing function's locals or from
 * the enclosing function's own upvalues (transitively).
 */
typedef enum {
    UPVAL_FROM_LOCAL,
    UPVAL_FROM_UPVAL,
} UpvalSource;

typedef struct {
    UpvalSource src;
    int idx; /* parent's local-slot or upvalue-slot */
} UpvalueRef;

/* ---------- variable references ----------
 * Resolved at parse time to one of these three kinds.
 */
typedef enum {
    VAR_LOCAL,   /* a local in the current function */
    VAR_UPVAL,   /* captured upvalue of the current function */
    VAR_BUILTIN, /* a predeclared builtin, idx = builtin id */
    VAR_GLOBAL,  /* a module-level global declared with `global x` */
} VarKind;

/* ---------- expressions ---------- */
typedef enum {
    EXPR_NIL,
    EXPR_TRUE,
    EXPR_FALSE,
    EXPR_INT,
    EXPR_FLOAT,
    EXPR_STRING,
    EXPR_VAR,
    EXPR_CALL,
    EXPR_BINOP,
    EXPR_UNOP,
    EXPR_FUNCTION,    /* anonymous function expression */
    EXPR_INDEX,       /* t[k]  (t.name is sugar lowered to INDEX with string key) */
    EXPR_TABLE,       /* { ... } table constructor */
    EXPR_METHOD_CALL, /* recv:name(args) — evaluates recv once */
    EXPR_VARARG,      /* `...` inside a vararg function */
} ExprKind;

typedef enum {
    TENT_POSITIONAL, /* value at next implicit positive integer index */
    TENT_KEY_EXPR,   /* [k] = v  -- and also t.name lowered as KEY_EXPR with string lit */
} TableEntryKind;

typedef struct {
    TableEntryKind kind;
    Expr *key; /* NULL for POSITIONAL */
    Expr *value;
} TableEntry;

typedef enum {
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_FDIV,
    BIN_MOD,
    BIN_POW,
    BIN_BAND,
    BIN_BOR,
    BIN_BXOR,
    BIN_SHL,
    BIN_SHR,
    BIN_CONCAT,
    BIN_EQ,
    BIN_NEQ,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
} BinOp;

typedef enum {
    UN_NEG,
    UN_NOT,
    UN_LEN,
    UN_BNOT,
} UnOp;

struct Expr {
    ExprKind kind;
    int line;
    /* Set when the expression was wrapped in parentheses: `(f())` is adjusted
     * to exactly one value, so it is never spliced as a multi-value tail. */
    int paren;
    union {
        int64_t i_val;
        double f_val;
        struct {
            const char *bytes;
            size_t len;
        } s;
        struct {
            const char *name;
            size_t name_len;
            VarKind kind;
            int idx; /* local slot or upvalue index, depending on kind */
        } var;
        struct {
            Expr *callee;
            Expr **args;
            size_t nargs;
        } call;
        struct {
            BinOp op;
            Expr *lhs;
            Expr *rhs;
        } binop;
        struct {
            UnOp op;
            Expr *operand;
        } unop;
        struct {
            LuaFunc *func;
        } func_expr;
        struct {
            Expr *table;
            Expr *key;
        } index;
        struct {
            TableEntry *entries;
            int n_entries;
        } table_ctor;
        struct {
            Expr *recv;
            const char *method;
            size_t method_len;
            Expr **args;
            size_t nargs;
        } method_call;
    } as;
};

/* ---------- statements ---------- */
typedef enum {
    STMT_LOCAL,  /* local name = expr */
    STMT_ASSIGN, /* name = expr (local or upvalue target) */
    STMT_EXPR,   /* call as statement */
    STMT_IF,
    STMT_WHILE,
    STMT_DO,
    STMT_RETURN,     /* return [expr] */
    STMT_LOCAL_FUNC, /* local function name(...) ... end */
    STMT_FOR_NUM,    /* for i = a, b [, c] do ... end */
    STMT_FOR_GEN,    /* for k [, v, ...] in expr_list do ... end */
    STMT_REPEAT,     /* repeat ... until cond */
    STMT_BREAK,
    STMT_GLOBAL, /* global name1 [, name2, ...] [= expr1, ...] */
    STMT_GOTO,   /* goto NAME */
    STMT_LABEL,  /* ::NAME:: */
} StmtKind;

struct Block {
    Stmt **items;
    size_t count;
};

typedef struct {
    Expr *cond;
    Block body;
} IfArm;

typedef struct {
    VarKind kind;
    int idx;
} VarRef;

typedef enum {
    TGT_VAR,
    TGT_INDEX,
} TargetKind;

typedef struct {
    TargetKind kind;
    union {
        VarRef var;
        struct {
            Expr *table;
            Expr *key;
        } index;
    } as;
} AssignTarget;

struct Stmt {
    StmtKind kind;
    int line;
    union {
        struct { /* local a [, b, c] [= e1 [, e2, ...]] */
            int n_names;
            int *local_idxs; /* one per name */
            int *attribs;    /* one per name: 0 = none, 1 = const, 2 = close (m23). NULL if none have any. */
            int n_values;
            Expr **values; /* may be 0 if no init */
        } local;
        struct { /* a [, b, c] = e1 [, e2, ...] */
            int n_targets;
            AssignTarget *targets;
            int n_values;
            Expr **values;
        } assign;
        struct {
            Expr *expr;
        } expr_stmt;
        struct {
            IfArm *arms;
            size_t narms;
            int has_else;
            Block else_body;
        } if_stmt;
        struct {
            Expr *cond;
            Block body;
        } while_stmt;
        struct {
            Block body;
        } do_stmt;
        struct { /* return [e1 [, e2, ...]] */
            int n_values;
            Expr **values;
        } return_stmt;
        struct {
            const char *name;
            size_t name_len;
            int local_idx;
            LuaFunc *func;
        } local_func;
        struct { /* for i = a, b [, c] do ... end */
            const char *name;
            size_t name_len;
            int local_idx;
            Expr *start;
            Expr *stop;
            Expr *step; /* NULL → 1 */
            Block body;
        } for_num;
        struct { /* for k [, v, ...] in exprs do ... end */
            int n_names;
            const char **names;
            size_t *name_lens;
            int *local_idxs;
            int n_exprs;
            Expr **exprs;
            Block body;
        } for_gen;
        struct { /* repeat body until cond */
            Block body;
            Expr *cond;
        } repeat;
        struct { /* global a [, b, ...] [= e, ...] */
            int n_names;
            int *global_idxs; /* assigned at parse time */
            int n_values;
            Expr **values;
        } global_decl;
        struct { /* goto NAME  /  ::NAME:: */
            const char *name;
            size_t name_len;
            /* Codegen pre-pass fills these in; parser leaves them zeroed.
             * Dispatch lowering handles any label graph (including interleaved
             * forward+backward scopes) by emitting a per-block
             * (loop $dispatch_BID) wrapping nested (block)s, with a br_table
             * on an i32 local $next_BID. */
            int id;                 /* (STMT_LABEL) unique label id */
            int segment_idx;        /* (STMT_LABEL) 1..N, position in block's label list */
            int block_dispatch_id;  /* (STMT_LABEL or STMT_GOTO) id of the enclosing dispatch block */
            int target_segment_idx; /* (STMT_GOTO)  segment number to land at */
            int close_base;         /* count of to-be-closed vars in scope here:
                                     * (STMT_LABEL) at the label; (STMT_GOTO) at the
                                     * target label. A goto closes down to this. */
        } label;
    } as;
};

/* ---------- a Lua function ----------
 * Each function definition gets one LuaFunc node, collected into a flat list
 * (`ParseResult.funcs`) so codegen can emit each as a top-level wasm function.
 */
struct LuaFunc {
    int func_idx;   /* unique id; used to name `$user_N` */
    int parent_idx; /* enclosing function's func_idx, or -1 for the
                     * main chunk; lets codegen resolve upvalue
                     * references back to their defining function. */
    int n_params;
    int n_locals; /* total locals, including params */
    UpvalueRef *upvalues;
    int n_upvalues;
    Block body;
    int line;
    int is_vararg; /* `function f(...)` or `function f(a, ...)` */
    /* Escape-analysis bitmap (size n_locals). captured[i] != 0 means some
     * descendant function references local slot i as an upvalue — that slot
     * must be heap-allocated as a $Box so the box can be shared with the
     * child closure. The common case (captured[i] == 0) lets codegen store
     * the local as a plain wasm `anyref`, skipping the box. */
    unsigned char *captured;
};

/* ---------- node pool ----------
 * Chunked bump allocator. Each chunk is a stable malloc'd block; once a
 * pointer is handed out, it remains valid until the entire pool is freed.
 * (Earlier realloc-based implementation silently invalidated previously-
 * returned pointers when the kernel had to relocate the buffer — see
 * test_pool_pointer_stability.) */
typedef struct PoolChunk PoolChunk;
typedef struct {
    PoolChunk *chunks; /* singly-linked list, most-recent first */
} NodePool;

void node_pool_init(NodePool *p);
void node_pool_free(NodePool *p);
void *node_pool_alloc(NodePool *p, size_t bytes);

Expr *expr_new(NodePool *p, ExprKind k, int line);
Stmt *stmt_new(NodePool *p, StmtKind k, int line);
LuaFunc *func_new(NodePool *p, int func_idx, int line);

#endif
