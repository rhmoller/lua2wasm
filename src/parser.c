#include "parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================
 * Function frames + scope analysis.
 *
 * A Parser maintains a stack of FuncFrames. Frame 0 is the implicit
 * top-level "chunk" function; nested `function`s push new frames.
 *
 * Each frame tracks:
 *   - its locals (visible only inside the frame; a block-mark/rewind
 *     mechanism lets per-block locals fall out of scope at `end`),
 *   - its upvalues: references to outer-frame locals or upvalues.
 *
 * When a name is looked up and resolves to a local in an outer frame,
 * each intermediate frame (between owner and current) registers an
 * upvalue, so closures only ever capture their *immediate* parent's
 * locals/upvalues. This matches Lua semantics.
 * ============================================================ */

#define MAX_LOCALS_PER_FN    256
#define MAX_UPVALS_PER_FN    64
#define MAX_FRAME_DEPTH      32
#define MAX_FUNCS            256

typedef struct {
    const char *name;
    size_t name_len;
    int slot;       /* wasm local index inside this function */
} LocalSlot;

typedef struct {
    LocalSlot locals[MAX_LOCALS_PER_FN];
    int local_count;       /* current count (block-rewindable) */
    int next_slot;         /* monotonic: never reused */
    UpvalueRef upvalues[MAX_UPVALS_PER_FN];
    int n_upvalues;
} FuncFrame;

typedef struct {
    const TokenList *toks;
    size_t pos;
    NodePool *pool;

    FuncFrame frames[MAX_FRAME_DEPTH];
    int frame_depth;       /* index of innermost frame; 0 = top-level */

    LuaFunc *funcs[MAX_FUNCS];
    int n_funcs;

    char error[256];
    int ok;
} Parser;

static FuncFrame *cur_frame(Parser *p) { return &p->frames[p->frame_depth]; }

static const Token *peek(Parser *p) { return &p->toks->items[p->pos]; }
static const Token *peek_at(Parser *p, size_t off) {
    size_t i = p->pos + off;
    if (i >= p->toks->count) i = p->toks->count - 1;
    return &p->toks->items[i];
}
static const Token *advance(Parser *p) { return &p->toks->items[p->pos++]; }

static void set_error(Parser *p, const char *msg) {
    if (!p->ok) return;
    snprintf(p->error, sizeof(p->error), "line %d: %s", peek(p)->line, msg);
    p->ok = 0;
}

static int match(Parser *p, TokKind k) {
    if (peek(p)->kind == k) { advance(p); return 1; }
    return 0;
}
static int expect(Parser *p, TokKind k, const char *what) {
    if (match(p, k)) return 1;
    char buf[160];
    snprintf(buf, sizeof(buf), "expected %s, got %s", what, tok_kind_name(peek(p)->kind));
    set_error(p, buf);
    return 0;
}

/* ----- frame operations ----- */

static void frame_init(FuncFrame *f) {
    f->local_count = 0;
    f->next_slot = 0;
    f->n_upvalues = 0;
}

static int frame_mark(FuncFrame *f) { return f->local_count; }
static void frame_rewind(FuncFrame *f, int mark) { f->local_count = mark; }

static int frame_declare(FuncFrame *f, const char *name, size_t name_len) {
    if (f->local_count >= MAX_LOCALS_PER_FN) return -1;
    int slot = f->next_slot++;
    f->locals[f->local_count++] = (LocalSlot){ .name = name, .name_len = name_len, .slot = slot };
    return slot;
}

static int frame_lookup_local(const FuncFrame *f, const char *name, size_t name_len) {
    for (int i = f->local_count - 1; i >= 0; i--) {
        if (f->locals[i].name_len == name_len &&
            memcmp(f->locals[i].name, name, name_len) == 0) {
            return f->locals[i].slot;
        }
    }
    return -1;
}

/* Register (or find existing) upvalue in the given frame. Returns upvalue idx. */
static int frame_add_upvalue(FuncFrame *f, UpvalSource src, int idx) {
    for (int i = 0; i < f->n_upvalues; i++) {
        if (f->upvalues[i].src == src && f->upvalues[i].idx == idx) return i;
    }
    if (f->n_upvalues >= MAX_UPVALS_PER_FN) return -1;
    f->upvalues[f->n_upvalues] = (UpvalueRef){ .src = src, .idx = idx };
    return f->n_upvalues++;
}

/* ----- name resolution -----
 * Returns:
 *   kind = VAR_LOCAL with out_idx = slot in innermost frame
 *   kind = VAR_UPVAL with out_idx = upvalue index in innermost frame
 *   kind = VAR_BUILTIN_PRINT
 * or returns 0 (NOT_FOUND) on failure.
 *
 * Side effect: adds upvalues to intermediate frames as needed.
 */
static int resolve_in_frame(Parser *p, int frame_idx, const char *name, size_t name_len,
                            VarKind *out_kind, int *out_idx) {
    FuncFrame *f = &p->frames[frame_idx];
    int slot = frame_lookup_local(f, name, name_len);
    if (slot >= 0) {
        *out_kind = VAR_LOCAL;
        *out_idx = slot;
        return 1;
    }
    if (frame_idx == 0) {
        /* top-level: try magic builtins */
        if (name_len == 5 && memcmp(name, "print", 5) == 0) {
            *out_kind = VAR_BUILTIN_PRINT;
            *out_idx = 0;
            return 1;
        }
        return 0;
    }
    /* recurse into parent */
    VarKind parent_kind;
    int parent_idx;
    if (!resolve_in_frame(p, frame_idx - 1, name, name_len, &parent_kind, &parent_idx)) {
        return 0;
    }
    if (parent_kind == VAR_BUILTIN_PRINT) {
        *out_kind = VAR_BUILTIN_PRINT;
        *out_idx = 0;
        return 1;
    }
    UpvalSource src = (parent_kind == VAR_LOCAL) ? UPVAL_FROM_LOCAL : UPVAL_FROM_UPVAL;
    int upval_idx = frame_add_upvalue(f, src, parent_idx);
    if (upval_idx < 0) {
        set_error(p, "too many upvalues");
        return 0;
    }
    *out_kind = VAR_UPVAL;
    *out_idx = upval_idx;
    return 1;
}

static int resolve_name(Parser *p, const char *name, size_t name_len,
                        VarKind *out_kind, int *out_idx) {
    return resolve_in_frame(p, p->frame_depth, name, name_len, out_kind, out_idx);
}

/* ============================================================
 * Expression parsing (Pratt). Returns NULL on error.
 * Operator precedence table mirrors Lua 5.5 §3.4.8:
 *   or
 *   and
 *   <  >  <=  >=  ~=  ==
 *   ..
 *   +  -
 *   *  /  //  %
 *   unary (- not #)
 *   ^   (right-assoc, higher than unary)
 * ============================================================ */

#define PREC_NONE   0
#define PREC_OR     1
#define PREC_AND    2
#define PREC_CMP    3
#define PREC_CONCAT 4
#define PREC_ADD    5
#define PREC_MUL    6
#define PREC_UNARY  7
#define PREC_POW    8

static int prec_of(TokKind k) {
    switch (k) {
        case TOK_KW_OR: return PREC_OR;
        case TOK_KW_AND: return PREC_AND;
        case TOK_EQ: case TOK_NEQ: case TOK_LT: case TOK_LE:
        case TOK_GT: case TOK_GE: return PREC_CMP;
        case TOK_CONCAT: return PREC_CONCAT;
        case TOK_PLUS: case TOK_MINUS: return PREC_ADD;
        case TOK_STAR: case TOK_SLASH: case TOK_DSLASH: case TOK_PERCENT: return PREC_MUL;
        case TOK_CARET: return PREC_POW;
        default: return PREC_NONE;
    }
}

static BinOp binop_of(TokKind k) {
    switch (k) {
        case TOK_PLUS:    return BIN_ADD;
        case TOK_MINUS:   return BIN_SUB;
        case TOK_STAR:    return BIN_MUL;
        case TOK_SLASH:   return BIN_DIV;
        case TOK_DSLASH:  return BIN_FDIV;
        case TOK_PERCENT: return BIN_MOD;
        case TOK_CARET:   return BIN_POW;
        case TOK_CONCAT:  return BIN_CONCAT;
        case TOK_EQ:      return BIN_EQ;
        case TOK_NEQ:     return BIN_NEQ;
        case TOK_LT:      return BIN_LT;
        case TOK_LE:      return BIN_LE;
        case TOK_GT:      return BIN_GT;
        case TOK_GE:      return BIN_GE;
        case TOK_KW_AND:  return BIN_AND;
        case TOK_KW_OR:   return BIN_OR;
        default:          return BIN_ADD;
    }
}

static Expr *parse_expr(Parser *p);
static Expr *parse_prec(Parser *p, int min_prec);
static LuaFunc *parse_function_body(Parser *p, int line);

static Expr *parse_primary(Parser *p) {
    const Token *t = peek(p);
    int line = t->line;
    switch (t->kind) {
        case TOK_KW_NIL:   advance(p); return expr_new(p->pool, EXPR_NIL,   line);
        case TOK_KW_TRUE:  advance(p); return expr_new(p->pool, EXPR_TRUE,  line);
        case TOK_KW_FALSE: advance(p); return expr_new(p->pool, EXPR_FALSE, line);
        case TOK_INT: {
            advance(p);
            Expr *e = expr_new(p->pool, EXPR_INT, line);
            e->as.i_val = t->i_val;
            return e;
        }
        case TOK_FLOAT: {
            advance(p);
            Expr *e = expr_new(p->pool, EXPR_FLOAT, line);
            e->as.f_val = t->f_val;
            return e;
        }
        case TOK_STRING: {
            advance(p);
            Expr *e = expr_new(p->pool, EXPR_STRING, line);
            e->as.s.bytes = t->str_buf;
            e->as.s.len = t->str_len;
            return e;
        }
        case TOK_IDENT: {
            advance(p);
            Expr *e = expr_new(p->pool, EXPR_VAR, line);
            e->as.var.name = t->start;
            e->as.var.name_len = t->len;
            VarKind kind;
            int idx;
            if (!resolve_name(p, t->start, t->len, &kind, &idx)) {
                char buf[160];
                snprintf(buf, sizeof(buf),
                    "undefined variable `%.*s` (phase 3a: locals/upvalues + `print` only)",
                    (int)t->len, t->start);
                set_error(p, buf);
                return NULL;
            }
            e->as.var.kind = kind;
            e->as.var.idx = idx;
            return e;
        }
        case TOK_LPAREN: {
            advance(p);
            Expr *inner = parse_expr(p);
            expect(p, TOK_RPAREN, ")");
            return inner;
        }
        case TOK_KW_FUNCTION: {
            advance(p);
            LuaFunc *fn = parse_function_body(p, line);
            if (!p->ok) return NULL;
            Expr *e = expr_new(p->pool, EXPR_FUNCTION, line);
            e->as.func_expr.func = fn;
            return e;
        }
        default:
            set_error(p, "expected expression");
            return NULL;
    }
}

static Expr *parse_unary(Parser *p) {
    const Token *t = peek(p);
    int line = t->line;
    UnOp op;
    if (t->kind == TOK_MINUS)        op = UN_NEG;
    else if (t->kind == TOK_KW_NOT)  op = UN_NOT;
    else if (t->kind == TOK_HASH)    op = UN_LEN;
    else {
        Expr *e = parse_primary(p);
        if (!p->ok) return NULL;
        /* postfix: call suffix. The callee can now be ANY expression. */
        while (peek(p)->kind == TOK_LPAREN) {
            int call_line = peek(p)->line;
            advance(p);
            Expr *args_buf[16];
            size_t nargs = 0;
            if (peek(p)->kind != TOK_RPAREN) {
                do {
                    if (nargs >= 16) { set_error(p, "too many args (>16)"); return NULL; }
                    args_buf[nargs++] = parse_expr(p);
                    if (!p->ok) return NULL;
                } while (match(p, TOK_COMMA));
            }
            expect(p, TOK_RPAREN, ")");
            Expr *call = expr_new(p->pool, EXPR_CALL, call_line);
            call->as.call.callee = e;
            call->as.call.nargs = nargs;
            call->as.call.args = node_pool_alloc(p->pool, sizeof(Expr *) * (nargs ? nargs : 1));
            for (size_t i = 0; i < nargs; i++) call->as.call.args[i] = args_buf[i];
            e = call;
        }
        return e;
    }
    advance(p);
    Expr *operand = parse_prec(p, PREC_UNARY);
    if (!p->ok) return NULL;
    Expr *e = expr_new(p->pool, EXPR_UNOP, line);
    e->as.unop.op = op;
    e->as.unop.operand = operand;
    return e;
}

static Expr *parse_prec(Parser *p, int min_prec) {
    Expr *lhs = parse_unary(p);
    if (!p->ok) return NULL;
    while (1) {
        TokKind k = peek(p)->kind;
        int prec = prec_of(k);
        if (prec < min_prec) break;
        int line = peek(p)->line;
        advance(p);
        int next_min = (k == TOK_CONCAT || k == TOK_CARET) ? prec : prec + 1;
        Expr *rhs = parse_prec(p, next_min);
        if (!p->ok) return NULL;
        Expr *n = expr_new(p->pool, EXPR_BINOP, line);
        n->as.binop.op = binop_of(k);
        n->as.binop.lhs = lhs;
        n->as.binop.rhs = rhs;
        lhs = n;
    }
    return lhs;
}

static Expr *parse_expr(Parser *p) { return parse_prec(p, PREC_OR); }

/* ============================================================ */

static void parse_block(Parser *p, Block *out, TokKind stop1, TokKind stop2, TokKind stop3);

static int is_block_end(TokKind k, TokKind s1, TokKind s2, TokKind s3) {
    return k == TOK_EOF || k == s1 || k == s2 || k == s3;
}

static Stmt *parse_local(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* local */

    /* local function name(...) ... end */
    if (peek(p)->kind == TOK_KW_FUNCTION) {
        advance(p); /* function */
        if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected function name"); return NULL; }
        const Token *name = advance(p);
        /* Declare the name in the current scope BEFORE parsing the body, so
         * the body can recursively reference itself. */
        int slot = frame_declare(cur_frame(p), name->start, name->len);
        if (slot < 0) { set_error(p, "too many locals"); return NULL; }
        LuaFunc *fn = parse_function_body(p, line);
        if (!p->ok) return NULL;
        Stmt *s = stmt_new(p->pool, STMT_LOCAL_FUNC, line);
        s->as.local_func.name = name->start;
        s->as.local_func.name_len = name->len;
        s->as.local_func.local_idx = slot;
        s->as.local_func.func = fn;
        return s;
    }

    /* local name [= expr] */
    if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected identifier after `local`"); return NULL; }
    const Token *name = advance(p);
    Expr *init = NULL;
    if (match(p, TOK_ASSIGN)) {
        init = parse_expr(p);
        if (!p->ok) return NULL;
    }
    int slot = frame_declare(cur_frame(p), name->start, name->len);
    if (slot < 0) { set_error(p, "too many locals"); return NULL; }
    Stmt *s = stmt_new(p->pool, STMT_LOCAL, line);
    s->as.local.name = name->start;
    s->as.local.name_len = name->len;
    s->as.local.init = init;
    s->as.local.local_idx = slot;
    return s;
}

static Stmt *parse_if(Parser *p) {
    int line = peek(p)->line;
    advance(p);
    IfArm arms_buf[16];
    size_t narms = 0;
    Expr *cond = parse_expr(p);
    if (!p->ok) return NULL;
    expect(p, TOK_KW_THEN, "then");
    Block body = {0};
    int mark = frame_mark(cur_frame(p));
    parse_block(p, &body, TOK_KW_ELSE, TOK_KW_ELSEIF, TOK_KW_END);
    frame_rewind(cur_frame(p), mark);
    if (!p->ok) return NULL;
    arms_buf[narms++] = (IfArm){ .cond = cond, .body = body };

    while (peek(p)->kind == TOK_KW_ELSEIF) {
        advance(p);
        Expr *c = parse_expr(p);
        if (!p->ok) return NULL;
        expect(p, TOK_KW_THEN, "then");
        Block b = {0};
        int m = frame_mark(cur_frame(p));
        parse_block(p, &b, TOK_KW_ELSE, TOK_KW_ELSEIF, TOK_KW_END);
        frame_rewind(cur_frame(p), m);
        if (!p->ok) return NULL;
        if (narms >= 16) { set_error(p, "too many elseif arms"); return NULL; }
        arms_buf[narms++] = (IfArm){ .cond = c, .body = b };
    }

    int has_else = 0;
    Block else_body = {0};
    if (match(p, TOK_KW_ELSE)) {
        has_else = 1;
        int m = frame_mark(cur_frame(p));
        parse_block(p, &else_body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
        frame_rewind(cur_frame(p), m);
        if (!p->ok) return NULL;
    }
    expect(p, TOK_KW_END, "end (of if)");

    Stmt *s = stmt_new(p->pool, STMT_IF, line);
    s->as.if_stmt.narms = narms;
    s->as.if_stmt.arms = node_pool_alloc(p->pool, sizeof(IfArm) * narms);
    for (size_t i = 0; i < narms; i++) s->as.if_stmt.arms[i] = arms_buf[i];
    s->as.if_stmt.has_else = has_else;
    s->as.if_stmt.else_body = else_body;
    return s;
}

static Stmt *parse_while(Parser *p) {
    int line = peek(p)->line;
    advance(p);
    Expr *cond = parse_expr(p);
    if (!p->ok) return NULL;
    expect(p, TOK_KW_DO, "do");
    Block body = {0};
    int mark = frame_mark(cur_frame(p));
    parse_block(p, &body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
    frame_rewind(cur_frame(p), mark);
    expect(p, TOK_KW_END, "end (of while)");
    if (!p->ok) return NULL;
    Stmt *s = stmt_new(p->pool, STMT_WHILE, line);
    s->as.while_stmt.cond = cond;
    s->as.while_stmt.body = body;
    return s;
}

static Stmt *parse_do(Parser *p) {
    int line = peek(p)->line;
    advance(p);
    Block body = {0};
    int mark = frame_mark(cur_frame(p));
    parse_block(p, &body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
    frame_rewind(cur_frame(p), mark);
    expect(p, TOK_KW_END, "end (of do)");
    if (!p->ok) return NULL;
    Stmt *s = stmt_new(p->pool, STMT_DO, line);
    s->as.do_stmt.body = body;
    return s;
}

static int looks_like_block_end(TokKind k) {
    return k == TOK_EOF || k == TOK_KW_END || k == TOK_KW_ELSE ||
           k == TOK_KW_ELSEIF || k == TOK_KW_UNTIL || k == TOK_SEMI;
}

static Stmt *parse_return(Parser *p) {
    int line = peek(p)->line;
    advance(p);
    Expr *value = NULL;
    if (!looks_like_block_end(peek(p)->kind)) {
        value = parse_expr(p);
        if (!p->ok) return NULL;
    }
    match(p, TOK_SEMI);
    Stmt *s = stmt_new(p->pool, STMT_RETURN, line);
    s->as.return_stmt.value = value;
    return s;
}

static Stmt *parse_ident_stmt(Parser *p) {
    int line = peek(p)->line;
    if (peek_at(p, 1)->kind == TOK_ASSIGN) {
        const Token *name = advance(p);
        advance(p);
        VarKind kind;
        int idx;
        if (!resolve_name(p, name->start, name->len, &kind, &idx)) {
            char buf[160];
            snprintf(buf, sizeof(buf),
                "assigning to undefined variable `%.*s`",
                (int)name->len, name->start);
            set_error(p, buf);
            return NULL;
        }
        if (kind == VAR_BUILTIN_PRINT) {
            set_error(p, "cannot reassign builtin `print` (phase 3a)");
            return NULL;
        }
        Expr *value = parse_expr(p);
        if (!p->ok) return NULL;
        Stmt *s = stmt_new(p->pool, STMT_ASSIGN, line);
        s->as.assign.name = name->start;
        s->as.assign.name_len = name->len;
        s->as.assign.value = value;
        s->as.assign.kind = kind;
        s->as.assign.idx = idx;
        return s;
    }
    Expr *e = parse_expr(p);
    if (!p->ok) return NULL;
    if (e->kind != EXPR_CALL) {
        set_error(p, "expression statement must be a function call");
        return NULL;
    }
    Stmt *s = stmt_new(p->pool, STMT_EXPR, line);
    s->as.expr_stmt.expr = e;
    return s;
}

static Stmt *parse_stmt(Parser *p) {
    switch (peek(p)->kind) {
        case TOK_SEMI: advance(p); return NULL;
        case TOK_KW_LOCAL:  return parse_local(p);
        case TOK_KW_IF:     return parse_if(p);
        case TOK_KW_WHILE:  return parse_while(p);
        case TOK_KW_DO:     return parse_do(p);
        case TOK_KW_RETURN: return parse_return(p);
        case TOK_IDENT:     return parse_ident_stmt(p);
        default:
            set_error(p, "expected a statement");
            return NULL;
    }
}

static void parse_block(Parser *p, Block *out, TokKind s1, TokKind s2, TokKind s3) {
    Stmt **vec = NULL;
    size_t count = 0, cap = 0;
    while (p->ok && !is_block_end(peek(p)->kind, s1, s2, s3)) {
        Stmt *st = parse_stmt(p);
        if (!p->ok) break;
        if (!st) continue;
        if (count == cap) { cap = cap ? cap * 2 : 8; vec = realloc(vec, cap * sizeof(Stmt *)); }
        vec[count++] = st;
    }
    out->count = count;
    if (count) {
        out->items = node_pool_alloc(p->pool, sizeof(Stmt *) * count);
        memcpy(out->items, vec, sizeof(Stmt *) * count);
    } else {
        out->items = NULL;
    }
    free(vec);
}

/* Parse `(params) body end` after a `function` keyword. Pushes/pops a frame. */
static LuaFunc *parse_function_body(Parser *p, int line) {
    if (p->n_funcs >= MAX_FUNCS) { set_error(p, "too many functions"); return NULL; }
    int func_idx = p->n_funcs;
    LuaFunc *fn = func_new(p->pool, func_idx, line);
    p->funcs[p->n_funcs++] = fn;

    if (p->frame_depth + 1 >= MAX_FRAME_DEPTH) {
        set_error(p, "function nesting too deep");
        return NULL;
    }
    p->frame_depth++;
    frame_init(cur_frame(p));

    expect(p, TOK_LPAREN, "( in function declaration");
    int n_params = 0;
    if (peek(p)->kind != TOK_RPAREN) {
        do {
            if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected parameter name"); break; }
            const Token *pn = advance(p);
            if (frame_declare(cur_frame(p), pn->start, pn->len) < 0) {
                set_error(p, "too many params"); break;
            }
            n_params++;
        } while (match(p, TOK_COMMA));
    }
    expect(p, TOK_RPAREN, ")");

    Block body = {0};
    parse_block(p, &body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
    expect(p, TOK_KW_END, "end (of function)");

    fn->n_params = n_params;
    fn->n_locals = cur_frame(p)->next_slot;
    fn->body = body;
    fn->n_upvalues = cur_frame(p)->n_upvalues;
    if (fn->n_upvalues) {
        fn->upvalues = node_pool_alloc(p->pool, sizeof(UpvalueRef) * fn->n_upvalues);
        memcpy(fn->upvalues, cur_frame(p)->upvalues, sizeof(UpvalueRef) * fn->n_upvalues);
    } else {
        fn->upvalues = NULL;
    }

    p->frame_depth--;
    return fn;
}

ParseResult parse(const TokenList *tokens, NodePool *pool) {
    Parser p = { .toks = tokens, .pool = pool, .ok = 1, .frame_depth = 0 };
    frame_init(&p.frames[0]);

    Block main = {0};
    parse_block(&p, &main, TOK_EOF, TOK_EOF, TOK_EOF);

    ParseResult r = {0};
    r.ok = p.ok;
    r.main_body = main;
    r.main_n_locals = p.frames[0].next_slot;
    r.funcs.count = (size_t)p.n_funcs;
    if (p.n_funcs) {
        r.funcs.items = malloc(sizeof(LuaFunc *) * p.n_funcs);
        memcpy(r.funcs.items, p.funcs, sizeof(LuaFunc *) * p.n_funcs);
    }
    if (!p.ok) memcpy(r.error, p.error, sizeof(r.error));
    return r;
}

void parse_result_free(ParseResult *r) {
    free(r->funcs.items);
    r->funcs.items = NULL;
    r->funcs.count = 0;
}
