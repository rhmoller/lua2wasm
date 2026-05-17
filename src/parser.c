#include "parser.h"
#include "builtins.h"
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
#define MAX_GLOBALS          256

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

    GlobalDecl globals[MAX_GLOBALS];
    int n_globals;

    char error[256];
    int ok;
} Parser;

static int globals_lookup(Parser *p, const char *name, size_t name_len) {
    for (int i = 0; i < p->n_globals; i++) {
        if (p->globals[i].name_len == name_len &&
            memcmp(p->globals[i].name, name, name_len) == 0) return i;
    }
    return -1;
}
static int globals_declare(Parser *p, const char *name, size_t name_len) {
    int existing = globals_lookup(p, name, name_len);
    if (existing >= 0) return existing;
    if (p->n_globals >= MAX_GLOBALS) return -1;
    p->globals[p->n_globals] = (GlobalDecl){ .name = name, .name_len = name_len };
    return p->n_globals++;
}

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
 *   kind = VAR_BUILTIN
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
        /* top-level: builtins first, then declared globals, then — matching
         * stock Lua's traditional behaviour — auto-declare any other name as
         * a fresh global. Read of an undeclared name therefore yields the
         * global's nil initialiser, and a bare `x = 42` works without a
         * `global x` prefix. Strict mode (compile error on undeclared) is a
         * future opt-in. */
        int b = lookup_builtin(name, name_len);
        if (b >= 0) { *out_kind = VAR_BUILTIN; *out_idx = b; return 1; }
        int g = globals_lookup(p, name, name_len);
        if (g < 0) g = globals_declare(p, name, name_len);
        if (g < 0) { set_error(p, "too many globals"); return 0; }
        *out_kind = VAR_GLOBAL;
        *out_idx = g;
        return 1;
    }
    /* recurse into parent */
    VarKind parent_kind;
    int parent_idx;
    if (!resolve_in_frame(p, frame_idx - 1, name, name_len, &parent_kind, &parent_idx)) {
        return 0;
    }
    if (parent_kind == VAR_BUILTIN) {
        *out_kind = VAR_BUILTIN;
        *out_idx = parent_idx;
        return 1;
    }
    if (parent_kind == VAR_GLOBAL) {
        /* Globals are visible everywhere — propagate without making an upvalue. */
        *out_kind = VAR_GLOBAL;
        *out_idx = parent_idx;
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
static LuaFunc *parse_function_body_ex(Parser *p, int line, int with_self);

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
        case TOK_LBRACE: {
            advance(p); /* { */
            TableEntry buf[64];
            int n = 0;
            while (peek(p)->kind != TOK_RBRACE && peek(p)->kind != TOK_EOF) {
                if (n >= 64) { set_error(p, "too many entries in constructor"); return NULL; }
                TableEntry *ent = &buf[n];
                if (peek(p)->kind == TOK_LBRACKET) {
                    advance(p);
                    Expr *k = parse_expr(p);
                    if (!p->ok) return NULL;
                    expect(p, TOK_RBRACKET, "]");
                    expect(p, TOK_ASSIGN, "=");
                    Expr *v = parse_expr(p);
                    if (!p->ok) return NULL;
                    ent->kind = TENT_KEY_EXPR;
                    ent->key = k; ent->value = v;
                } else if (peek(p)->kind == TOK_IDENT &&
                           peek_at(p, 1)->kind == TOK_ASSIGN) {
                    const Token *nm = advance(p);
                    advance(p); /* = */
                    Expr *v = parse_expr(p);
                    if (!p->ok) return NULL;
                    Expr *k = expr_new(p->pool, EXPR_STRING, nm->line);
                    k->as.s.bytes = nm->start;
                    k->as.s.len = nm->len;
                    ent->kind = TENT_KEY_EXPR;
                    ent->key = k; ent->value = v;
                } else {
                    Expr *v = parse_expr(p);
                    if (!p->ok) return NULL;
                    ent->kind = TENT_POSITIONAL;
                    ent->key = NULL; ent->value = v;
                }
                n++;
                if (!match(p, TOK_COMMA) && !match(p, TOK_SEMI)) break;
            }
            expect(p, TOK_RBRACE, "}");
            Expr *e = expr_new(p->pool, EXPR_TABLE, line);
            e->as.table_ctor.n_entries = n;
            e->as.table_ctor.entries = node_pool_alloc(p->pool, sizeof(TableEntry) * (n ? n : 1));
            for (int i = 0; i < n; i++) e->as.table_ctor.entries[i] = buf[i];
            return e;
        }
        default:
            set_error(p, "expected expression");
            return NULL;
    }
}

/* primary + postfix (call/dot/bracket) chain — used in expressions AND
 * for assignment-target parsing. */
static Expr *parse_prefix_chain(Parser *p) {
    Expr *e = parse_primary(p);
    if (!p->ok) return NULL;
    while (1) {
        TokKind k = peek(p)->kind;
        if (k == TOK_LPAREN) {
            int call_line = peek(p)->line;
            advance(p);
            Expr *args_buf[16];
            size_t nargs = 0;
            if (peek(p)->kind != TOK_RPAREN) {
                do {
                    if (nargs >= 16) { set_error(p, "too many args"); return NULL; }
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
        } else if (k == TOK_DOT) {
            advance(p);
            if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected field name after '.'"); return NULL; }
            const Token *nm = advance(p);
            Expr *key = expr_new(p->pool, EXPR_STRING, nm->line);
            key->as.s.bytes = nm->start;
            key->as.s.len = nm->len;
            Expr *idx = expr_new(p->pool, EXPR_INDEX, nm->line);
            idx->as.index.table = e;
            idx->as.index.key = key;
            e = idx;
        } else if (k == TOK_LBRACKET) {
            int line = peek(p)->line;
            advance(p);
            Expr *key = parse_expr(p);
            if (!p->ok) return NULL;
            expect(p, TOK_RBRACKET, "]");
            Expr *idx = expr_new(p->pool, EXPR_INDEX, line);
            idx->as.index.table = e;
            idx->as.index.key = key;
            e = idx;
        } else if (k == TOK_STRING || k == TOK_LBRACE) {
            /* Paren-less single-arg call: `f "x"` or `f{k=1}` — only one
             * argument. The arg is either the immediate string literal or a
             * table constructor parsed as a primary. */
            int call_line = peek(p)->line;
            Expr *arg;
            if (k == TOK_STRING) {
                const Token *t = advance(p);
                arg = expr_new(p->pool, EXPR_STRING, t->line);
                arg->as.s.bytes = t->str_buf;
                arg->as.s.len = t->str_len;
            } else {
                arg = parse_primary(p);
                if (!p->ok) return NULL;
            }
            Expr *call = expr_new(p->pool, EXPR_CALL, call_line);
            call->as.call.callee = e;
            call->as.call.nargs = 1;
            call->as.call.args = node_pool_alloc(p->pool, sizeof(Expr *));
            call->as.call.args[0] = arg;
            e = call;
        } else if (k == TOK_COLON) {
            /* method call: recv:name(args) */
            int line = peek(p)->line;
            advance(p); /* : */
            if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected method name after ':'"); return NULL; }
            const Token *nm = advance(p);
            expect(p, TOK_LPAREN, "(");
            Expr *args_buf[16];
            size_t nargs = 0;
            if (peek(p)->kind != TOK_RPAREN) {
                do {
                    if (nargs >= 16) { set_error(p, "too many args"); return NULL; }
                    args_buf[nargs++] = parse_expr(p);
                    if (!p->ok) return NULL;
                } while (match(p, TOK_COMMA));
            }
            expect(p, TOK_RPAREN, ")");
            Expr *mc = expr_new(p->pool, EXPR_METHOD_CALL, line);
            mc->as.method_call.recv = e;
            mc->as.method_call.method = nm->start;
            mc->as.method_call.method_len = nm->len;
            mc->as.method_call.nargs = nargs;
            mc->as.method_call.args = node_pool_alloc(p->pool, sizeof(Expr *) * (nargs ? nargs : 1));
            for (size_t i = 0; i < nargs; i++) mc->as.method_call.args[i] = args_buf[i];
            e = mc;
        } else break;
    }
    return e;
}

static Expr *parse_unary(Parser *p) {
    const Token *t = peek(p);
    int line = t->line;
    UnOp op;
    if (t->kind == TOK_MINUS)        op = UN_NEG;
    else if (t->kind == TOK_KW_NOT)  op = UN_NOT;
    else if (t->kind == TOK_HASH)    op = UN_LEN;
    else return parse_prefix_chain(p);
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

    /* local name [, name, ...] [= expr [, expr, ...]] */
    if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected identifier after `local`"); return NULL; }
    const Token *names_buf[16];
    int n_names = 0;
    names_buf[n_names++] = advance(p);
    while (match(p, TOK_COMMA)) {
        if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected identifier"); return NULL; }
        if (n_names >= 16) { set_error(p, "too many names in local"); return NULL; }
        names_buf[n_names++] = advance(p);
    }
    /* Parse RHS values BEFORE declaring locals — Lua scoping rule. */
    Expr *vals_buf[16];
    int n_values = 0;
    if (match(p, TOK_ASSIGN)) {
        do {
            if (n_values >= 16) { set_error(p, "too many values in local"); return NULL; }
            vals_buf[n_values++] = parse_expr(p);
            if (!p->ok) return NULL;
        } while (match(p, TOK_COMMA));
    }
    /* Now declare locals. */
    int *local_idxs = node_pool_alloc(p->pool, sizeof(int) * n_names);
    for (int i = 0; i < n_names; i++) {
        int slot = frame_declare(cur_frame(p), names_buf[i]->start, names_buf[i]->len);
        if (slot < 0) { set_error(p, "too many locals"); return NULL; }
        local_idxs[i] = slot;
    }
    Stmt *s = stmt_new(p->pool, STMT_LOCAL, line);
    s->as.local.n_names = n_names;
    s->as.local.local_idxs = local_idxs;
    s->as.local.n_values = n_values;
    if (n_values) {
        s->as.local.values = node_pool_alloc(p->pool, sizeof(Expr *) * n_values);
        for (int i = 0; i < n_values; i++) s->as.local.values[i] = vals_buf[i];
    }
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
    Expr *vals_buf[16];
    int n_values = 0;
    if (!looks_like_block_end(peek(p)->kind)) {
        do {
            if (n_values >= 16) { set_error(p, "too many return values"); return NULL; }
            vals_buf[n_values++] = parse_expr(p);
            if (!p->ok) return NULL;
        } while (match(p, TOK_COMMA));
    }
    match(p, TOK_SEMI);
    Stmt *s = stmt_new(p->pool, STMT_RETURN, line);
    s->as.return_stmt.n_values = n_values;
    if (n_values) {
        s->as.return_stmt.values = node_pool_alloc(p->pool, sizeof(Expr *) * n_values);
        for (int i = 0; i < n_values; i++) s->as.return_stmt.values[i] = vals_buf[i];
    }
    return s;
}

static AssignTarget expr_to_target(Expr *e) {
    AssignTarget t = {0};
    if (e->kind == EXPR_VAR) {
        t.kind = TGT_VAR;
        t.as.var.kind = e->as.var.kind;
        t.as.var.idx = e->as.var.idx;
    } else {
        t.kind = TGT_INDEX;
        t.as.index.table = e->as.index.table;
        t.as.index.key = e->as.index.key;
    }
    return t;
}

static Stmt *parse_ident_stmt(Parser *p) {
    int line = peek(p)->line;
    Expr *first = parse_prefix_chain(p);
    if (!p->ok) return NULL;

    if (first->kind == EXPR_CALL || first->kind == EXPR_METHOD_CALL) {
        Stmt *s = stmt_new(p->pool, STMT_EXPR, line);
        s->as.expr_stmt.expr = first;
        return s;
    }
    if (first->kind != EXPR_VAR && first->kind != EXPR_INDEX) {
        set_error(p, "expression statement must be a call or assignment");
        return NULL;
    }
    if (first->kind == EXPR_VAR && first->as.var.kind == VAR_BUILTIN) {
        set_error(p, "cannot reassign builtin `print`");
        return NULL;
    }

    AssignTarget targets[16];
    int n_targets = 0;
    targets[n_targets++] = expr_to_target(first);
    while (match(p, TOK_COMMA)) {
        if (n_targets >= 16) { set_error(p, "too many assignment targets"); return NULL; }
        Expr *t = parse_prefix_chain(p);
        if (!p->ok) return NULL;
        if (t->kind != EXPR_VAR && t->kind != EXPR_INDEX) {
            set_error(p, "invalid assignment target"); return NULL;
        }
        if (t->kind == EXPR_VAR && t->as.var.kind == VAR_BUILTIN) {
            set_error(p, "cannot reassign builtin `print`"); return NULL;
        }
        targets[n_targets++] = expr_to_target(t);
    }
    expect(p, TOK_ASSIGN, "= (assignment)");
    if (!p->ok) return NULL;
    Expr *vals_buf[16];
    int n_values = 0;
    do {
        if (n_values >= 16) { set_error(p, "too many values"); return NULL; }
        vals_buf[n_values++] = parse_expr(p);
        if (!p->ok) return NULL;
    } while (match(p, TOK_COMMA));
    Stmt *s = stmt_new(p->pool, STMT_ASSIGN, line);
    s->as.assign.n_targets = n_targets;
    s->as.assign.targets = node_pool_alloc(p->pool, sizeof(AssignTarget) * n_targets);
    for (int i = 0; i < n_targets; i++) s->as.assign.targets[i] = targets[i];
    s->as.assign.n_values = n_values;
    s->as.assign.values = node_pool_alloc(p->pool, sizeof(Expr *) * n_values);
    for (int i = 0; i < n_values; i++) s->as.assign.values[i] = vals_buf[i];
    return s;
}

static Stmt *parse_for(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* for */
    if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected identifier after `for`"); return NULL; }
    const Token *first = advance(p);
    if (peek(p)->kind == TOK_ASSIGN) {
        /* numeric */
        advance(p);
        Expr *start = parse_expr(p);
        if (!p->ok) return NULL;
        expect(p, TOK_COMMA, ",");
        Expr *stop = parse_expr(p);
        if (!p->ok) return NULL;
        Expr *step = NULL;
        if (match(p, TOK_COMMA)) {
            step = parse_expr(p);
            if (!p->ok) return NULL;
        }
        expect(p, TOK_KW_DO, "do");
        int mark = frame_mark(cur_frame(p));
        int slot = frame_declare(cur_frame(p), first->start, first->len);
        if (slot < 0) { set_error(p, "too many locals"); return NULL; }
        Block body = {0};
        parse_block(p, &body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
        frame_rewind(cur_frame(p), mark);
        expect(p, TOK_KW_END, "end (of for)");
        if (!p->ok) return NULL;
        Stmt *s = stmt_new(p->pool, STMT_FOR_NUM, line);
        s->as.for_num.name = first->start;
        s->as.for_num.name_len = first->len;
        s->as.for_num.local_idx = slot;
        s->as.for_num.start = start;
        s->as.for_num.stop = stop;
        s->as.for_num.step = step;
        s->as.for_num.body = body;
        return s;
    }
    /* generic: for k [, v, ...] in expr_list do ... end */
    const Token *names[16];
    int n_names = 0;
    names[n_names++] = first;
    while (match(p, TOK_COMMA)) {
        if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected name"); return NULL; }
        if (n_names >= 16) { set_error(p, "too many for-vars"); return NULL; }
        names[n_names++] = advance(p);
    }
    expect(p, TOK_KW_IN, "in");
    Expr *exprs[16];
    int n_exprs = 0;
    do {
        if (n_exprs >= 16) { set_error(p, "too many exprs in for"); return NULL; }
        exprs[n_exprs++] = parse_expr(p);
        if (!p->ok) return NULL;
    } while (match(p, TOK_COMMA));
    expect(p, TOK_KW_DO, "do");
    int mark = frame_mark(cur_frame(p));
    int *local_idxs = node_pool_alloc(p->pool, sizeof(int) * n_names);
    const char **names_arr = node_pool_alloc(p->pool, sizeof(char *) * n_names);
    size_t *lens_arr = node_pool_alloc(p->pool, sizeof(size_t) * n_names);
    for (int i = 0; i < n_names; i++) {
        int slot = frame_declare(cur_frame(p), names[i]->start, names[i]->len);
        if (slot < 0) { set_error(p, "too many locals"); return NULL; }
        local_idxs[i] = slot;
        names_arr[i] = names[i]->start;
        lens_arr[i] = names[i]->len;
    }
    Block body = {0};
    parse_block(p, &body, TOK_KW_END, TOK_KW_END, TOK_KW_END);
    frame_rewind(cur_frame(p), mark);
    expect(p, TOK_KW_END, "end (of for)");
    if (!p->ok) return NULL;
    Stmt *s = stmt_new(p->pool, STMT_FOR_GEN, line);
    s->as.for_gen.n_names = n_names;
    s->as.for_gen.names = names_arr;
    s->as.for_gen.name_lens = lens_arr;
    s->as.for_gen.local_idxs = local_idxs;
    s->as.for_gen.n_exprs = n_exprs;
    s->as.for_gen.exprs = node_pool_alloc(p->pool, sizeof(Expr *) * n_exprs);
    for (int i = 0; i < n_exprs; i++) s->as.for_gen.exprs[i] = exprs[i];
    s->as.for_gen.body = body;
    return s;
}

static Stmt *parse_repeat(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* repeat */
    Block body = {0};
    int mark = frame_mark(cur_frame(p));
    parse_block(p, &body, TOK_KW_UNTIL, TOK_KW_UNTIL, TOK_KW_UNTIL);
    /* `until cond` is evaluated in scope where the loop's locals are still visible */
    expect(p, TOK_KW_UNTIL, "until");
    Expr *cond = parse_expr(p);
    frame_rewind(cur_frame(p), mark);
    if (!p->ok) return NULL;
    Stmt *s = stmt_new(p->pool, STMT_REPEAT, line);
    s->as.repeat.body = body;
    s->as.repeat.cond = cond;
    return s;
}

static Stmt *parse_break(Parser *p) {
    int line = peek(p)->line;
    advance(p);
    Stmt *s = stmt_new(p->pool, STMT_BREAK, line);
    return s;
}

static Stmt *parse_global(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* global */
    if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected identifier after `global`"); return NULL; }
    const Token *names_buf[16];
    int n_names = 0;
    names_buf[n_names++] = advance(p);
    while (match(p, TOK_COMMA)) {
        if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected identifier"); return NULL; }
        if (n_names >= 16) { set_error(p, "too many names in global"); return NULL; }
        names_buf[n_names++] = advance(p);
    }
    /* Register globals BEFORE parsing values so they can self-reference. */
    int *global_idxs = node_pool_alloc(p->pool, sizeof(int) * n_names);
    for (int i = 0; i < n_names; i++) {
        int idx = globals_declare(p, names_buf[i]->start, names_buf[i]->len);
        if (idx < 0) { set_error(p, "too many globals"); return NULL; }
        global_idxs[i] = idx;
    }
    Expr *vals_buf[16];
    int n_values = 0;
    if (match(p, TOK_ASSIGN)) {
        do {
            if (n_values >= 16) { set_error(p, "too many values"); return NULL; }
            vals_buf[n_values++] = parse_expr(p);
            if (!p->ok) return NULL;
        } while (match(p, TOK_COMMA));
    }
    Stmt *s = stmt_new(p->pool, STMT_GLOBAL, line);
    s->as.global_decl.n_names = n_names;
    s->as.global_decl.global_idxs = global_idxs;
    s->as.global_decl.n_values = n_values;
    if (n_values) {
        s->as.global_decl.values = node_pool_alloc(p->pool, sizeof(Expr *) * n_values);
        for (int i = 0; i < n_values; i++) s->as.global_decl.values[i] = vals_buf[i];
    }
    return s;
}

/* `function NAME (.NAME)* (:NAME)? (params) body end` — top-level form.
 * Lowers to an assignment whose target is built from the dotted path and
 * whose value is an EXPR_FUNCTION. The `:` variant prepends an implicit
 * `self` parameter to the function. */
static Stmt *parse_function_stmt(Parser *p) {
    int line = peek(p)->line;
    advance(p); /* function */
    if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected function name"); return NULL; }
    const Token *first = advance(p);
    VarKind kind;
    int idx;
    if (!resolve_name(p, first->start, first->len, &kind, &idx)) {
        char buf[160];
        snprintf(buf, sizeof(buf),
            "function `%.*s` is not declared (add `global %.*s` first or use `local function`)",
            (int)first->len, first->start, (int)first->len, first->start);
        set_error(p, buf);
        return NULL;
    }
    if (kind == VAR_BUILTIN) { set_error(p, "cannot redefine a builtin"); return NULL; }
    /* Build the base expression for the path. */
    Expr *base = expr_new(p->pool, EXPR_VAR, line);
    base->as.var.name = first->start;
    base->as.var.name_len = first->len;
    base->as.var.kind = kind;
    base->as.var.idx = idx;

    /* Walk .NAME chain (intermediate field access). */
    while (peek(p)->kind == TOK_DOT) {
        advance(p);
        if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected name after '.'"); return NULL; }
        const Token *nm = advance(p);
        Expr *key = expr_new(p->pool, EXPR_STRING, nm->line);
        key->as.s.bytes = nm->start;
        key->as.s.len = nm->len;
        Expr *idxe = expr_new(p->pool, EXPR_INDEX, nm->line);
        idxe->as.index.table = base;
        idxe->as.index.key = key;
        base = idxe;
    }
    /* Optional :METHOD suffix. */
    int with_self = 0;
    if (peek(p)->kind == TOK_COLON) {
        advance(p);
        if (peek(p)->kind != TOK_IDENT) { set_error(p, "expected name after ':'"); return NULL; }
        const Token *nm = advance(p);
        Expr *key = expr_new(p->pool, EXPR_STRING, nm->line);
        key->as.s.bytes = nm->start;
        key->as.s.len = nm->len;
        Expr *idxe = expr_new(p->pool, EXPR_INDEX, nm->line);
        idxe->as.index.table = base;
        idxe->as.index.key = key;
        base = idxe;
        with_self = 1;
    }
    /* base is now the assignment target. */
    AssignTarget target;
    if (base->kind == EXPR_VAR) {
        target.kind = TGT_VAR;
        target.as.var.kind = base->as.var.kind;
        target.as.var.idx = base->as.var.idx;
    } else {
        target.kind = TGT_INDEX;
        target.as.index.table = base->as.index.table;
        target.as.index.key = base->as.index.key;
    }

    LuaFunc *fn = parse_function_body_ex(p, line, with_self);
    if (!p->ok) return NULL;
    Expr *func_expr = expr_new(p->pool, EXPR_FUNCTION, line);
    func_expr->as.func_expr.func = fn;

    Stmt *s = stmt_new(p->pool, STMT_ASSIGN, line);
    s->as.assign.n_targets = 1;
    s->as.assign.targets = node_pool_alloc(p->pool, sizeof(AssignTarget));
    s->as.assign.targets[0] = target;
    s->as.assign.n_values = 1;
    s->as.assign.values = node_pool_alloc(p->pool, sizeof(Expr *));
    s->as.assign.values[0] = func_expr;
    return s;
}

static Stmt *parse_stmt(Parser *p) {
    switch (peek(p)->kind) {
        case TOK_SEMI: advance(p); return NULL;
        case TOK_KW_LOCAL:    return parse_local(p);
        case TOK_KW_FUNCTION: return parse_function_stmt(p);
        case TOK_KW_IF:     return parse_if(p);
        case TOK_KW_WHILE:  return parse_while(p);
        case TOK_KW_DO:     return parse_do(p);
        case TOK_KW_RETURN: return parse_return(p);
        case TOK_KW_FOR:    return parse_for(p);
        case TOK_KW_REPEAT: return parse_repeat(p);
        case TOK_KW_BREAK:  return parse_break(p);
        case TOK_IDENT: {
            /* `global x ...` is parsed as if `global` were a keyword, but we
             * keep it as a normal identifier in the lexer for backward-compat
             * and check for it here. */
            const Token *t = peek(p);
            if (t->len == 6 && memcmp(t->start, "global", 6) == 0) {
                return parse_global(p);
            }
            return parse_ident_stmt(p);
        }
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

/* Parse `(params) body end` after a `function` keyword. Pushes/pops a frame.
 * If `with_self`, an implicit "self" parameter is declared first (for the
 * `:` method-definition sugar). */
static LuaFunc *parse_function_body_ex(Parser *p, int line, int with_self);

static LuaFunc *parse_function_body(Parser *p, int line) {
    return parse_function_body_ex(p, line, /*with_self*/0);
}

static LuaFunc *parse_function_body_ex(Parser *p, int line, int with_self) {
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

    int n_params = 0;
    if (with_self) {
        /* implicit `self` for : method definitions */
        frame_declare(cur_frame(p), "self", 4);
        n_params++;
    }
    expect(p, TOK_LPAREN, "( in function declaration");
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
    /* Pre-declare stdlib library tables and well-known globals so user code can name them. */
    globals_declare(&p, "math",     4);
    globals_declare(&p, "string",   6);
    globals_declare(&p, "io",       2);
    globals_declare(&p, "table",    5);
    globals_declare(&p, "_VERSION", 8);

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
    r.globals.count = (size_t)p.n_globals;
    if (p.n_globals) {
        r.globals.items = malloc(sizeof(GlobalDecl) * p.n_globals);
        memcpy(r.globals.items, p.globals, sizeof(GlobalDecl) * p.n_globals);
    }
    if (!p.ok) memcpy(r.error, p.error, sizeof(r.error));
    return r;
}

void parse_result_free(ParseResult *r) {
    free(r->funcs.items);
    r->funcs.items = NULL;
    r->funcs.count = 0;
    free(r->globals.items);
    r->globals.items = NULL;
    r->globals.count = 0;
}
