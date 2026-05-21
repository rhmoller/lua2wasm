#include "codegen.h"
#include "builtins.h"
#include "xalloc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Size of the shared $fmt_buf scratch array (bytes). The runtime chunks
 * large reads/formats through it, so three sites must agree on this number:
 * the allocation below, the chunk bounds in runtime/prelude.wat, and
 * FMT_BUF_CAP in runtime/host-bindings.mjs. */
#define LUA_FMT_BUF_CAP 16384

/* ============================================================
 * Codegen v3a.
 *
 * Value representation: every Lua value is `anyref`.
 *   nil      -> (ref.null any)
 *   false    -> global $g_false   : (ref $LuaBool) struct{ i32 0 }
 *   true     -> global $g_true    : (ref $LuaBool) struct{ i32 1 }
 *   int      -> i31ref (small) | (struct.new $LuaInt i64) (overflow)
 *   float    -> (struct.new $LuaFloat f64)
 *   string   -> (struct.new $LuaString (array i8))
 *   function -> (ref $LuaClosure)
 *
 * Closure runtime:
 *   $Box       = struct { mut anyref v }     -- shared mutable cell
 *   $ArgArr    = array (mut anyref)
 *   $UpvalArr  = array (mut (ref $Box))
 *   $LuaFn     = func ((ref $LuaClosure) (ref $ArgArr)) -> anyref
 *   $LuaClosure = struct { (ref $LuaFn) code, (ref $UpvalArr) upvals }
 *
 * Locals (and parameters) captured by an inner closure are stored in $Box
 * cells so the box can be shared and stay mutable; the parser's escape
 * analysis (LuaFunc.captured) flags which slots need boxing, and the rest
 * are emitted as plain wasm `anyref` slots (see slot_is_boxed).
 *
 * Each Lua function in source becomes a top-level wasm function named
 * `$user_N` (N = LuaFunc.func_idx). The implicit chunk becomes `$main`,
 * which has no closure/args parameters and no return value.
 * ============================================================ */

/* ----- string-literal pool ----- */
typedef struct {
    char *bytes;
    size_t used;
    size_t cap;
} StrPool;

typedef struct {
    size_t offset;
    size_t len;
} StrRef;

/* Find an existing run of exactly these bytes anywhere in the pool. The
 * data segment is a flat byte array addressed by (offset, len), so any
 * matching run can be shared — including overlap with a longer string or
 * with the fixed LITERAL_PREFIX. Returns SIZE_MAX if absent. */
static size_t strpool_find(const StrPool *p, const char *bytes, size_t len) {
    if (len == 0) return 0;            /* zero bytes read => any offset works */
    if (len > p->used) return SIZE_MAX;
    for (size_t i = 0; i + len <= p->used; i++)
        if (memcmp(p->bytes + i, bytes, len) == 0) return i;
    return SIZE_MAX;
}

/* Intern a byte run, returning its (offset, len). Deduplicates: a run that
 * already appears in the pool is reused rather than re-appended, which keeps
 * repeated keys (metamethod names, "__index", library keys) single-copy in
 * the emitted $str_data segment. */
static StrRef strpool_add(StrPool *p, const char *bytes, size_t len) {
    size_t found = strpool_find(p, bytes, len);
    if (found != SIZE_MAX) return (StrRef){ .offset = found, .len = len };
    if (p->used + len > p->cap) {
        size_t new_cap = p->cap ? p->cap : 64;
        while (p->used + len > new_cap) new_cap *= 2;
        p->bytes = xrealloc(p->bytes, new_cap);
        p->cap = new_cap;
    }
    StrRef r = { .offset = p->used, .len = len };
    memcpy(p->bytes + p->used, bytes, len);
    p->used += len;
    return r;
}

/* ----- label-scope stack for goto / ::label:: -----
 *
 * Each block that declares one or more labels pushes a LabelScope while
 * we emit it. emit_stmt looks up `goto NAME` by walking the parent chain.
 *
 * The codegen runs a pre-pass that fills in
 * Stmt.as.label.{id,segment_idx,block_dispatch_id,target_segment_idx} so
 * emit_block can wrap each label-bearing block in a (loop $dispatch_BID)
 * and route gotos through a br_table on $next_BID. */
typedef struct LabelScope {
    Stmt **labels;          /* pointers to STMT_LABEL nodes in this block */
    int n;
    int cur_idx;            /* updated during walk: current stmt index */
    struct LabelScope *parent;
} LabelScope;

/* ----- whole-program numeric signatures (LUA2WASM_OPT_INT) -----
 * Parameter + return unboxing. In Lua 5.5 integer and float are distinct types
 * (3*3 == 9 but 3.0*3.0 == 9.0), so they are *incomparable*: a value seen as
 * both must stay boxed (NT_ANY) — unboxing it to one machine type would change
 * the result. The lattice is therefore NT_UNSET (top, "no evidence yet") above
 * the two incomparable concretes NT_INT / NT_FLOAT, above NT_ANY (bottom). */
typedef enum { NT_ANY = 0, NT_INT, NT_FLOAT, NT_UNSET } NumTy;
typedef struct {
    NumTy *param_ty;   /* [n_params]; NULL when n_params == 0 */
    int    n_params;
    NumTy  ret_ty;     /* single-value return type, NT_ANY if not monomorphic */
    int    has_site;   /* a direct-call site somewhere targets this function */
} FuncSig;

/* ----- codegen context ----- */
typedef struct {
    WatBuilder *w;
    const ParseResult *pr;   /* for VAR_GLOBAL name lookup */
    StrPool strs;
    int next_label;
    int in_main;            /* 1 while emitting $main body, 0 inside user fn */
    int break_labels[64];   /* break targets for nested while/for/repeat */
    int break_depth;
    int for_depth;          /* nesting depth of numeric/generic for-loops;
                             * indexes per-level $for_* scratch locals so a
                             * nested loop can't clobber the enclosing loop's
                             * stop/step or iterator state */
    /* Escape-analysis context for the currently-emitted body: cur_captured[s]
     * != 0 means slot s must be heap-boxed (some descendant function captures
     * it); cur_captured[s] == 0 lets the slot be a plain wasm anyref. Set
     * before emitting either a user function body or the main chunk. */
    const unsigned char *cur_captured;
    int cur_n_locals;
    /* Integer-specialization PoC (opt-in via LUA2WASM_OPT_INT). When on,
     * cur_is_int[s] != 0 marks a local slot proven to hold only integers; it
     * is declared as an unboxed i64 and integer arithmetic on it is emitted as
     * inline i64 ops, boxed to a Lua value only at use-site boundaries. */
    int opt_int;
    const unsigned char *cur_is_int;
    const unsigned char *cur_is_float;   /* slots proven float-only -> unboxed f64 */
    /* Direct-call PoC (lever 3): cur_func_slot[s] != NULL means local slot s is
     * statically bound to that LuaFunc (a non-captured, never-reassigned local
     * function), so a call f(args) of matching arity can skip the $ArgArr and
     * invoke the function's direct-args entry $user_N_da. */
    const LuaFunc **cur_func_slot;
    int ret_single;          /* emitting a $user_N_da1 body: return one value */
    NumTy cur_ret_ty;        /* result type of the $user_N_da1 body being emitted */
    /* Whole-program inferred signatures, indexed by func_idx (opt_int only). */
    FuncSig *sigs;
    int n_sigs;
    /* Global direct-call binding maps (opt_int): which LuaFunc a local slot /
     * upvalue of each function statically (and stably) resolves to. Unlike the
     * per-body func-slot scan these include captured-but-never-reassigned
     * functions, so self-recursive `local function`s become direct-call targets.
     * bind_slot/bind_upval are indexed by func_idx; main's locals live in
     * main_slot_func (main has no upvalues). */
    const LuaFunc ***bind_slot;
    const LuaFunc ***bind_upval;
    const LuaFunc **main_slot_func;
    int cur_func_idx;               /* func_idx of the body being emitted; -1 = main */
    const LuaFunc **cur_upval_func; /* upvalue->LuaFunc map for that body */
    int cur_n_params;
    /* goto/label state */
    int next_label_id;      /* fresh per function body */
    LabelScope *label_scope; /* innermost first */
    char err[256];
    int ok;
} CG;

/* True iff the local at this slot index must be allocated as a $Box. */
static int slot_is_boxed(const CG *c, int slot) {
    if (slot < 0 || slot >= c->cur_n_locals) return 1; /* defensive */
    return c->cur_captured ? c->cur_captured[slot] : 1;
}

static void cg_error(CG *c, const char *msg) {
    if (!c->ok) return;
    c->ok = 0;
    snprintf(c->err, sizeof(c->err), "codegen: %s", msg);
}

/* Push a loop's break target onto the fixed-size stack. Returns 0 (after
 * setting cg_error) if loop nesting exceeds the stack — callers `break` out
 * of the statement on failure so the depth stays balanced, instead of
 * silently writing past break_labels. */
static int push_break_label(CG *c, int label) {
    int cap = (int)(sizeof(c->break_labels) / sizeof(c->break_labels[0]));
    if (c->break_depth >= cap) {
        cg_error(c, "loop nesting too deep");
        return 0;
    }
    c->break_labels[c->break_depth++] = label;
    return 1;
}

/* ----- goto/label pre-pass -----
 *
 * Walks the function body to:
 *   1. Assign each STMT_LABEL a unique id.
 *   2. Resolve each STMT_GOTO to a target label by lexical lookup
 *      through enclosing blocks; error if unresolved.
 *   3. Copy the target's block_dispatch_id / segment_idx onto the goto so
 *      emit can route it through the right block's br_table.
 *
 * Scope chain mirrors block nesting. For each block we keep an array of
 * the label stmts it declares, no AST pollution.
 */

typedef struct LabelAnalysisScope {
    Stmt *labels[64];       /* up to 64 labels per single block */
    int n;
    struct LabelAnalysisScope *parent;
} LabelAnalysisScope;

/* Resolve a goto to its target label by walking the scope chain outward.
 * Returns the matching label stmt, or NULL on miss. */
static Stmt *la_lookup(LabelAnalysisScope *scope, const char *name, size_t len) {
    for (LabelAnalysisScope *s = scope; s; s = s->parent) {
        for (int i = 0; i < s->n; i++) {
            Stmt *lab = s->labels[i];
            if (lab->as.label.name_len == len &&
                memcmp(lab->as.label.name, name, len) == 0) {
                return lab;
            }
        }
    }
    return NULL;
}

static void la_block(CG *c, const Block *b, LabelAnalysisScope *parent);

static void la_recurse_stmt(CG *c, Stmt *s, LabelAnalysisScope *scope) {
    switch (s->kind) {
    case STMT_DO:      la_block(c, &s->as.do_stmt.body,    scope); break;
    case STMT_WHILE:   la_block(c, &s->as.while_stmt.body, scope); break;
    case STMT_REPEAT:  la_block(c, &s->as.repeat.body,     scope); break;
    case STMT_FOR_NUM: la_block(c, &s->as.for_num.body,    scope); break;
    case STMT_FOR_GEN: la_block(c, &s->as.for_gen.body,    scope); break;
    case STMT_IF:
        for (size_t i = 0; i < s->as.if_stmt.narms; i++)
            la_block(c, &s->as.if_stmt.arms[i].body, scope);
        if (s->as.if_stmt.has_else)
            la_block(c, &s->as.if_stmt.else_body, scope);
        break;
    /* STMT_LOCAL_FUNC and inline function expressions start a fresh
     * label namespace; emit_user_function runs the pre-pass on those
     * separately when it descends. */
    default: break;
    }
}

static void la_block(CG *c, const Block *b, LabelAnalysisScope *parent) {
    LabelAnalysisScope scope = { .n = 0, .parent = parent };
    /* Pass 1: collect labels, dedup, assign ids. */
    for (size_t i = 0; i < b->count; i++) {
        Stmt *st = b->items[i];
        if (st->kind != STMT_LABEL) continue;
        if (scope.n >= 64) {
            cg_error(c, "too many labels in one block (limit 64)");
            return;
        }
        for (int j = 0; j < scope.n; j++) {
            Stmt *prev = scope.labels[j];
            if (prev->as.label.name_len == st->as.label.name_len &&
                memcmp(prev->as.label.name, st->as.label.name,
                       st->as.label.name_len) == 0) {
                char msg[128];
                int n = (int)(st->as.label.name_len < 80 ? st->as.label.name_len : 80);
                snprintf(msg, sizeof(msg),
                    "label '%.*s' already defined in this block",
                    n, st->as.label.name);
                cg_error(c, msg);
                return;
            }
        }
        st->as.label.id = c->next_label_id++;
        st->as.label.segment_idx = scope.n + 1; /* 1-based; segment 0 is "before any label" */
        scope.labels[scope.n] = st;
        scope.n++;
    }
    /* All labels in this block share the same dispatch-block id: by
     * convention the id of the first label declared in the block. */
    int block_dispatch_id = scope.n > 0 ? scope.labels[0]->as.label.id : -1;
    for (int i = 0; i < scope.n; i++) {
        scope.labels[i]->as.label.block_dispatch_id = block_dispatch_id;
    }
    /* Pass 2: resolve gotos in this block, recurse into nested blocks. */
    for (size_t i = 0; i < b->count; i++) {
        Stmt *st = b->items[i];
        if (st->kind == STMT_GOTO) {
            Stmt *lab = la_lookup(&scope, st->as.label.name, st->as.label.name_len);
            if (!lab) {
                char msg[128];
                int n = (int)(st->as.label.name_len < 80 ? st->as.label.name_len : 80);
                snprintf(msg, sizeof(msg),
                    "no visible label '%.*s' for goto", n, st->as.label.name);
                cg_error(c, msg);
                return;
            }
            st->as.label.block_dispatch_id = lab->as.label.block_dispatch_id;
            st->as.label.target_segment_idx = lab->as.label.segment_idx;
        } else if (st->kind != STMT_LABEL) {
            la_recurse_stmt(c, st, &scope);
        }
    }
}

static void emit_indent(CG *c, int depth) {
    for (int i = 0; i < depth; i++) wat_append(c->w, "  ");
}

static int i31_fits(int64_t v) {
    return v >= -(int64_t)0x40000000 && v < (int64_t)0x40000000;
}

/* ----- forward decls ----- */
static void emit_expr(CG *c, const Expr *e, int depth);
static void emit_block(CG *c, const Block *b, int depth);
static void emit_stmt(CG *c, const Stmt *s, int depth);
static int  expr_is_int(CG *c, const Expr *e);
static void emit_int_expr(CG *c, const Expr *e, int depth);
static int  expr_is_float(CG *c, const Expr *e);
static void emit_float_expr(CG *c, const Expr *e, int depth);
static void emit_num_as_f64(CG *c, const Expr *e, int depth);

/* ----- literal emission ----- */
static void emit_int_literal(CG *c, int64_t v, int depth) {
    emit_indent(c, depth);
    if (i31_fits(v)) {
        wat_appendf(c->w, "(ref.i31 (i32.const %lld))\n", (long long)v);
    } else {
        wat_appendf(c->w, "(struct.new $LuaInt (i64.const %lld))\n", (long long)v);
    }
}

static void emit_float_literal(CG *c, double v, int depth) {
    emit_indent(c, depth);
    wat_appendf(c->w, "(struct.new $LuaFloat (f64.const %.17g))\n", v);
}

static void emit_string_literal(CG *c, const char *bytes, size_t len, int depth) {
    StrRef r = strpool_add(&c->strs, bytes, len);
    emit_indent(c, depth);
    wat_appendf(c->w,
        "(struct.new $LuaString "
        "(array.new_data $LuaArr $str_data (i32.const %zu) (i32.const %zu)))\n",
        r.offset, r.len);
}

/* ----- variable read / write -----
 * VAR_UPVAL is only emitted inside user functions (parser guarantees this:
 * main has no upvalues to capture).
 */
/* Emit a `(struct.new $LuaString ...)` expression carrying the name of a
 * global. Used by every global read/write — the same name is pooled once
 * and reused at every site via $str_data offsets. */
static void emit_global_key(CG *c, const char *name, size_t name_len) {
    StrRef sr = strpool_add(&c->strs, name, name_len);
    wat_appendf(c->w,
        "(struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const %zu) (i32.const %zu)))\n",
        sr.offset, sr.len);
}

/* `(call $tab_set (local.get $tgt) "key" (global.get $g_<glob>))` — the
 * shape used everywhere stdlib_init wires a builtin closure into a
 * library table or a sub-table like a file handle. */
static void emit_tab_set_global(WatBuilder *out, const char *tgt,
                                StrRef key, const char *glob) {
    wat_appendf(out,
        "    (call $tab_set (local.get %s)\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const %zu) (i32.const %zu)))\n"
        "      (global.get $g_%s))\n",
        tgt, key.offset, key.len, glob);
}

/* `(global.set <glob> "<s>")` — set a wasm global to an interned string. */
static void emit_global_set_str(CG *c, const char *glob, const char *s, size_t len) {
    StrRef sr = strpool_add(&c->strs, s, len);
    wat_appendf(c->w,
        "    (global.set %s\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const %zu) (i32.const %zu))))\n",
        glob, sr.offset, sr.len);
}

/* `(call $tab_set <target> "<key>" <value>)` where <target> and <value>
 * are complete WAT expressions. The general form behind every stdlib_init
 * table install whose value isn't itself a plain string. */
static void emit_tab_set_str(CG *c, const char *target,
                             const char *key, size_t klen, const char *value) {
    StrRef sr = strpool_add(&c->strs, key, klen);
    wat_appendf(c->w,
        "    (call $tab_set %s\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const %zu) (i32.const %zu)))\n"
        "      %s)\n",
        target, sr.offset, sr.len, value);
}

/* `(call $tab_set <target> "<key>" "<val>")` — install a string-valued
 * entry; both key and value are interned (and deduplicated). */
static void emit_tab_set_strval(CG *c, const char *target, const char *key,
                                size_t klen, const char *val, size_t vlen) {
    StrRef ks = strpool_add(&c->strs, key, klen);
    StrRef vs = strpool_add(&c->strs, val, vlen);
    wat_appendf(c->w,
        "    (call $tab_set %s\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const %zu) (i32.const %zu)))\n"
        "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
        "        (i32.const %zu) (i32.const %zu))))\n",
        target, ks.offset, ks.len, vs.offset, vs.len);
}

static void emit_global_read(CG *c, const char *name, size_t name_len, int depth) {
    emit_indent(c, depth);
    wat_append(c->w, "(call $tab_get (ref.as_non_null (global.get $g_globals))\n");
    emit_indent(c, depth + 1);
    emit_global_key(c, name, name_len);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

static void emit_var_read(CG *c, VarKind kind, int idx, int depth) {
    switch (kind) {
        case VAR_LOCAL:
            emit_indent(c, depth);
            if (slot_is_boxed(c, idx)) {
                wat_appendf(c->w, "(struct.get $Box $v (local.get $L%d))\n", idx);
            } else {
                wat_appendf(c->w, "(local.get $L%d)\n", idx);
            }
            break;
        case VAR_UPVAL:
            emit_indent(c, depth);
            wat_appendf(c->w,
                "(struct.get $Box $v (array.get $UpvalArr "
                "(struct.get $LuaClosure $upvals (local.get $closure)) "
                "(i32.const %d)))\n", idx);
            break;
        case VAR_BUILTIN: {
            /* Read via $g_globals so user reassignment is honoured. */
            const char *name = builtin_name(idx);
            emit_global_read(c, name, strlen(name), depth);
            break;
        }
        case VAR_GLOBAL: {
            const char *name = c->pr->globals.items[idx].name;
            size_t nl = c->pr->globals.items[idx].name_len;
            emit_global_read(c, name, nl, depth);
            break;
        }
    }
}

/* Emit code that pushes the (ref $Box) for the named binding (not its value).
 * Used for upvalue capture into a child closure. Globals and builtins don't
 * have boxes. Invariant: any local reached here must have been flagged
 * captured during name resolution, so it really is boxed at codegen time. */
static void emit_box_ref(CG *c, VarKind kind, int idx, int depth) {
    emit_indent(c, depth);
    switch (kind) {
        case VAR_LOCAL:
            if (!slot_is_boxed(c, idx)) {
                cg_error(c, "internal: emit_box_ref on unboxed local");
                return;
            }
            wat_appendf(c->w, "(local.get $L%d)\n", idx);
            break;
        case VAR_UPVAL:
            wat_appendf(c->w,
                "(array.get $UpvalArr "
                "(struct.get $LuaClosure $upvals (local.get $closure)) "
                "(i32.const %d))\n", idx);
            break;
        case VAR_BUILTIN:
        case VAR_GLOBAL:
            cg_error(c, "cannot take a box reference to a builtin/global");
            break;
    }
}

/* Open the "store to this target" expression. The caller must then emit the
 * value expression as a child, then call emit_target_close(). */
static void emit_target_open(CG *c, const AssignTarget *t, int depth) {
    if (t->kind == TGT_VAR) {
        switch (t->as.var.kind) {
            case VAR_LOCAL:
                if (slot_is_boxed(c, t->as.var.idx)) {
                    emit_indent(c, depth); wat_append(c->w, "(struct.set $Box $v\n");
                    emit_box_ref(c, VAR_LOCAL, t->as.var.idx, depth + 1);
                } else {
                    emit_indent(c, depth);
                    wat_appendf(c->w, "(local.set $L%d\n", t->as.var.idx);
                }
                break;
            case VAR_UPVAL:
                emit_indent(c, depth); wat_append(c->w, "(struct.set $Box $v\n");
                emit_box_ref(c, t->as.var.kind, t->as.var.idx, depth + 1);
                break;
            case VAR_BUILTIN:
            case VAR_GLOBAL: {
                /* Assignment to any global (including a name that
                 * happens to also be a builtin like `print`) routes
                 * through $g_globals via $tab_set. */
                const char *name;
                size_t name_len;
                if (t->as.var.kind == VAR_BUILTIN) {
                    name = builtin_name(t->as.var.idx);
                    name_len = strlen(name);
                } else {
                    name = c->pr->globals.items[t->as.var.idx].name;
                    name_len = c->pr->globals.items[t->as.var.idx].name_len;
                }
                emit_indent(c, depth);
                wat_append(c->w, "(call $tab_set (ref.as_non_null (global.get $g_globals))\n");
                emit_indent(c, depth + 1);
                emit_global_key(c, name, name_len);
                break;
            }
        }
    } else {
        /* User-code assignment goes through \$lua_tabset so __newindex
         * has a chance to fire. Table constructors emit \$tab_set
         * directly since freshly built tables have no metatable. */
        emit_indent(c, depth); wat_append(c->w, "(call $lua_tabset\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_expr(c, t->as.index.key, depth + 1);
    }
}
static void emit_target_close(CG *c, const AssignTarget *t, int depth) {
    (void)t;
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* ----- binary / unary ops ----- */
static const char *binop_helper(BinOp op) {
    switch (op) {
        case BIN_ADD:    return "$lua_add";
        case BIN_SUB:    return "$lua_sub";
        case BIN_MUL:    return "$lua_mul";
        case BIN_DIV:    return "$lua_div";
        case BIN_FDIV:   return "$lua_fdiv";
        case BIN_MOD:    return "$lua_mod";
        case BIN_POW:    return "$lua_pow";
        case BIN_CONCAT: return "$lua_concat";
        case BIN_EQ:     return "$lua_eq";
        case BIN_NEQ:    return "$lua_neq";
        case BIN_LT:     return "$lua_lt";
        case BIN_LE:     return "$lua_le";
        case BIN_GT:     return "$lua_gt";
        case BIN_GE:     return "$lua_ge";
        case BIN_BAND:   return "$lua_band";
        case BIN_BOR:    return "$lua_bor";
        case BIN_BXOR:   return "$lua_bxor";
        case BIN_SHL:    return "$lua_shl";
        case BIN_SHR:    return "$lua_shr";
        default:         return "$lua_add";
    }
}

static void emit_binop(CG *c, const Expr *e, int depth) {
    BinOp op = e->as.binop.op;
    if (op == BIN_AND || op == BIN_OR) {
        int label = c->next_label++;
        emit_indent(c, depth);
        wat_appendf(c->w, "(block $sc_%d (result anyref)\n", label);

        emit_expr(c, e->as.binop.lhs, depth + 1);
        emit_indent(c, depth + 1); wat_append(c->w, "local.set $tmp_any\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(call $lua_truthy (local.get $tmp_any))\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(if (then\n");
        if (op == BIN_AND) {
            emit_expr(c, e->as.binop.rhs, depth + 2);
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $sc_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            emit_indent(c, depth + 1); wat_append(c->w, "local.get $tmp_any\n");
        } else {
            emit_indent(c, depth + 2); wat_append(c->w, "local.get $tmp_any\n");
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $sc_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            emit_expr(c, e->as.binop.rhs, depth + 1);
        }
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    emit_expr(c, e->as.binop.lhs, depth);
    emit_expr(c, e->as.binop.rhs, depth);
    emit_indent(c, depth);
    wat_appendf(c->w, "(call %s)\n", binop_helper(op));
}

static void emit_unop(CG *c, const Expr *e, int depth) {
    emit_expr(c, e->as.unop.operand, depth);
    emit_indent(c, depth);
    switch (e->as.unop.op) {
        case UN_NEG:  wat_append(c->w, "(call $lua_neg)\n");  break;
        case UN_NOT:  wat_append(c->w, "(call $lua_not)\n");  break;
        case UN_LEN:  wat_append(c->w, "(call $lua_len)\n");  break;
        case UN_BNOT: wat_append(c->w, "(call $lua_bnot)\n"); break;
    }
}

/* An expression whose value in a multi-value position is a full $ArgArr
 * (call/method-call/vararg) rather than a single anyref. */
static int is_multival_tail(const Expr *e) {
    if (e->paren) return 0;   /* `(f())` is adjusted to a single value */
    return e->kind == EXPR_CALL ||
           e->kind == EXPR_METHOD_CALL ||
           e->kind == EXPR_VARARG;
}

/* Emit (ref $ArgArr) for a multi-value expression (last-in-list context). */
static void emit_call_array(CG *c, const Expr *e, int depth);
static void emit_multival_array(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_VARARG) {
        emit_indent(c, depth);
        wat_append(c->w, "(local.get $varargs)\n");
        return;
    }
    emit_call_array(c, e, depth);
}

/* If `e` is a call whose callee statically (and stably) resolves to a known
 * LuaFunc, invoked with exactly its parameter count and no multi-value-splat
 * argument, return that LuaFunc: the call can go to the direct entry
 * $user_N_da/_da1 and skip building an $ArgArr. Otherwise NULL.
 *
 *   - VAR_LOCAL: a never-reassigned local function, *including a captured one*
 *     (so a self-recursive `local function fib` is reachable from its defining
 *     scope, which bootstraps the typed recursion below).
 *   - VAR_UPVAL: only *self-recursion* (the upvalue resolves to the function
 *     being emitted). This makes recursive `local function`s like fib direct
 *     without making cross-function upvalue calls direct — the latter would
 *     skip the callee's frame and degrade error()/traceback positions. */
static const LuaFunc *direct_call_target(CG *c, const Expr *e) {
    if (!c->opt_int || e->kind != EXPR_CALL) return NULL;
    const Expr *callee = e->as.call.callee;
    if (callee->kind != EXPR_VAR) return NULL;
    const LuaFunc *K = NULL;
    int idx = callee->as.var.idx;
    if (callee->as.var.kind == VAR_LOCAL) {
        if (c->cur_func_slot && idx >= 0 && idx < c->cur_n_locals) K = c->cur_func_slot[idx];
    } else if (callee->as.var.kind == VAR_UPVAL) {
        if (c->cur_upval_func && idx >= 0) {
            K = c->cur_upval_func[idx];
            if (K && K->func_idx != c->cur_func_idx) K = NULL;  /* self-recursion only */
        }
    }
    if (!K || K->is_vararg || (int)e->as.call.nargs != K->n_params) return NULL;
    for (size_t i = 0; i < e->as.call.nargs; i++)
        if (is_multival_tail(e->as.call.args[i])) return NULL;
    return K;
}

/* The inferred signature of a direct-call target, or NULL when unavailable. */
static const FuncSig *target_sig(CG *c, const LuaFunc *K) {
    if (!K || !c->sigs || K->func_idx < 0 || K->func_idx >= c->n_sigs) return NULL;
    return &c->sigs[K->func_idx];
}

/* The numeric type of `e` in the current context (NT_INT/NT_FLOAT/NT_ANY). */
static NumTy expr_num_ty(CG *c, const Expr *e) {
    if (expr_is_int(c, e)) return NT_INT;
    if (expr_is_float(c, e)) return NT_FLOAT;
    return NT_ANY;
}

/* Can a direct call to K reach its typed _da/_da1 entry from here? Each argument
 * must be emittable at its parameter's declared numeric type (an f64 param also
 * accepts an int arg, which is converted at the call). When K's params are all
 * NT_ANY this is always true, matching the original (untyped) direct-args path. */
static int direct_args_typed_ok(CG *c, const Expr *e, const LuaFunc *K) {
    const FuncSig *sg = target_sig(c, K);
    if (!sg) return 0;
    for (size_t i = 0; i < e->as.call.nargs; i++) {
        NumTy pt = sg->param_ty ? sg->param_ty[i] : NT_ANY;
        const Expr *a = e->as.call.args[i];
        if (pt == NT_INT && !expr_is_int(c, a)) return 0;
        if (pt == NT_FLOAT && !expr_is_int(c, a) && !expr_is_float(c, a)) return 0;
    }
    return 1;
}

/* Emit each argument of a direct call at its parameter's declared numeric type:
 * a raw i64 for NT_INT, a raw f64 for NT_FLOAT, else a boxed anyref. */
static void emit_typed_args(CG *c, const Expr *e, const FuncSig *sg, int depth) {
    for (size_t i = 0; i < e->as.call.nargs; i++) {
        NumTy pt = (sg && sg->param_ty) ? sg->param_ty[i] : NT_ANY;
        const Expr *a = e->as.call.args[i];
        if (pt == NT_INT)        emit_int_expr(c, a, depth);
        else if (pt == NT_FLOAT) emit_num_as_f64(c, a, depth);
        else                     emit_expr(c, a, depth);
    }
}

/* Emit a direct call to K's single-value entry $user_K_da1 (closure + typed
 * args). The result lands as the entry's declared type: raw i64/f64 when K has a
 * numeric ret_ty, otherwise a single anyref. Callers ensure args are typed-ok. */
static void emit_typed_direct_call1(CG *c, const Expr *e, const LuaFunc *K, int depth) {
    const FuncSig *sg = target_sig(c, K);
    emit_indent(c, depth);
    wat_appendf(c->w, "(call $user_%d_da1\n", K->func_idx);
    emit_indent(c, depth + 1); wat_append(c->w, "(ref.cast (ref $LuaClosure)\n");
    emit_expr(c, e->as.call.callee, depth + 2);
    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    emit_typed_args(c, e, sg, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* Build a (ref $ArgArr) from a sequence of argument expressions, splicing
 * the trailing expression's full multi-value result if it is a call or `...`. */
static void emit_args_array(CG *c, Expr **args, size_t nargs, int depth) {
    if (nargs == 0) {
        emit_indent(c, depth); wat_append(c->w, "(global.get $g_empty_args)\n");
        return;
    }
    int last_mv = is_multival_tail(args[nargs - 1]);
    if (!last_mv) {
        emit_indent(c, depth);
        wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", nargs);
        for (size_t i = 0; i < nargs; i++) emit_expr(c, args[i], depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    size_t singles = nargs - 1;
    emit_indent(c, depth); wat_append(c->w, "(call $merge_args\n");
    if (singles == 0) {
        emit_indent(c, depth + 1); wat_append(c->w, "(global.get $g_empty_args)\n");
    } else {
        emit_indent(c, depth + 1);
        wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", singles);
        for (size_t i = 0; i < singles; i++) emit_expr(c, args[i], depth + 2);
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    }
    emit_multival_array(c, args[nargs - 1], depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* Emit a call returning (ref $ArgArr) — the full multi-value result. */
static void emit_call_array(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL) {
        /* obj:m(args). Evaluate receiver once into $tmp_any, look up the
         * method via $lua_index (which redirects strings through the
         * `string` library), then call with receiver prepended. */
        StrRef sr = strpool_add(&c->strs, e->as.method_call.method, e->as.method_call.method_len);
        emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_any\n");
        emit_expr(c, e->as.method_call.recv, depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        emit_indent(c, depth); wat_append(c->w, "(call $lua_call_any\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(call $lua_index\n");
        emit_indent(c, depth + 2); wat_append(c->w, "(local.get $tmp_any)\n");
        emit_indent(c, depth + 2);
        wat_appendf(c->w,
            "(struct.new $LuaString (array.new_data $LuaArr $str_data "
            "(i32.const %zu) (i32.const %zu)))\n", sr.offset, sr.len);
        emit_indent(c, depth + 2);
        wat_appendf(c->w, "(i32.const %d)\n", e->line);
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
        /* args = [recv] ++ method args */
        size_t mna = e->as.method_call.nargs;
        int has_mv = mna > 0 && is_multival_tail(e->as.method_call.args[mna - 1]);
        emit_indent(c, depth + 1); wat_append(c->w, "(call $merge_args\n");
        emit_indent(c, depth + 2);
        wat_append(c->w, "(array.new_fixed $ArgArr 1 (local.get $tmp_any))\n");
        if (mna == 0) {
            emit_indent(c, depth + 2); wat_append(c->w, "(global.get $g_empty_args)\n");
        } else if (!has_mv) {
            emit_indent(c, depth + 2);
            wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", mna);
            for (size_t i = 0; i < mna; i++) emit_expr(c, e->as.method_call.args[i], depth + 3);
            emit_indent(c, depth + 2); wat_append(c->w, ")\n");
        } else {
            emit_args_array(c, e->as.method_call.args, mna, depth + 2);
        }
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
        emit_indent(c, depth + 1);
        wat_appendf(c->w, "(i32.const %d)\n", e->line);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    const LuaFunc *dt = direct_call_target(c, e);
    if (dt && direct_args_typed_ok(c, e, dt)) {
        /* Direct-args call: pass the closure + (typed) args to $user_N_da,
         * no $ArgArr allocation. Returns the result array like $lua_call_any.
         * (Frame push/pop is skipped — a known function needs no __call walk;
         * error positions inside it fall back to the caller's frame, matching
         * the project's "error position not tracked" stance.) */
        emit_indent(c, depth);
        wat_appendf(c->w, "(call $user_%d_da\n", dt->func_idx);
        emit_indent(c, depth + 1); wat_append(c->w, "(ref.cast (ref $LuaClosure)\n");
        emit_expr(c, e->as.call.callee, depth + 2);
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
        emit_typed_args(c, e, target_sig(c, dt), depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    emit_indent(c, depth); wat_append(c->w, "(call $lua_call_any\n");
    emit_expr(c, e->as.call.callee, depth + 1);
    emit_args_array(c, e->as.call.args, e->as.call.nargs, depth + 1);
    emit_indent(c, depth + 1);
    wat_appendf(c->w, "(i32.const %d)\n", e->line);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* In expression context we want a single anyref; wrap with $args_first. */
static void emit_call(CG *c, const Expr *e, int depth) {
    const LuaFunc *dt = direct_call_target(c, e);
    if (dt && direct_args_typed_ok(c, e, dt)) {
        /* Single-value direct call: invoke the $user_N_da1 entry, which returns
         * one value directly — no $ArgArr and no $args_first. A numeric-returning
         * call is routed through emit_int/float_expr upstream (expr_is_int/float),
         * so when we get here ret_ty is ANY and $user_N_da1 yields one anyref. */
        emit_typed_direct_call1(c, e, dt, depth);
        return;
    }
    emit_indent(c, depth); wat_append(c->w, "(call $args_first\n");
    emit_call_array(c, e, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* Tail-call dispatch shared by the regular and method forms. Assumes the
 * callee value is in $tmp_callee and the argument array in $tmp_args. Fast
 * path: a real closure -> return_call_ref, so deep recursion runs in
 * constant wasm stack. Slow path: fall through to $lua_call_any (which
 * walks __call metamethods and throws a typed error for non-callables);
 * TCO is lost there, which is fine for a metamethod hop. */
static void emit_tail_dispatch(CG *c, int line, int depth) {
    /* Fast path: real closure -> return_call_ref. Update the top frame
     * line so error()/traceback see this site instead of the (now-defunct)
     * caller's. */
    emit_indent(c, depth);
    wat_append(c->w, "(if (ref.test (ref $LuaClosure) (local.get $tmp_callee))\n");
    emit_indent(c, depth + 1); wat_append(c->w, "(then\n");
    emit_indent(c, depth + 2);
    wat_appendf(c->w, "(call $replace_top_call_frame (i32.const %d))\n", line);
    emit_indent(c, depth + 2);
    wat_append(c->w, "(local.set $tmp_clo (ref.cast (ref $LuaClosure) (local.get $tmp_callee)))\n");
    emit_indent(c, depth + 2); wat_append(c->w, "(return_call_ref $LuaFn\n");
    emit_indent(c, depth + 3);
    wat_append(c->w, "(ref.as_non_null (local.get $tmp_clo))\n");
    emit_indent(c, depth + 3);
    wat_append(c->w, "(ref.as_non_null (local.get $tmp_args))\n");
    emit_indent(c, depth + 3);
    wat_append(c->w, "(struct.get $LuaClosure $code (ref.as_non_null (local.get $tmp_clo))))))\n");
    /* Slow path: __call walk / typed error. */
    emit_indent(c, depth);
    wat_appendf(c->w,
        "(return (call $lua_call_any (local.get $tmp_callee) "
        "(ref.as_non_null (local.get $tmp_args)) (i32.const %d)))\n",
        line);
}

/* `return obj:m(args)` — the method-call tail form. Mirrors emit_call_array's
 * method branch (receiver once into $tmp_any; method via $lua_index; args =
 * [recv] ++ method args), but parks the callee/args in $tmp_callee/$tmp_args
 * and hands off to emit_tail_dispatch so it gets the same TCO as a plain
 * `return f(args)`. The receiver is read into the [recv] fixed array before
 * the method args are evaluated, so an arg that itself reuses $tmp_any can't
 * clobber it. */
static void emit_tail_method_call(CG *c, const Expr *e, int depth) {
    StrRef sr = strpool_add(&c->strs, e->as.method_call.method,
                            e->as.method_call.method_len);
    emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_any\n");
    emit_expr(c, e->as.method_call.recv, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
    emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_callee\n");
    emit_indent(c, depth + 1); wat_append(c->w, "(call $lua_index\n");
    emit_indent(c, depth + 2); wat_append(c->w, "(local.get $tmp_any)\n");
    emit_indent(c, depth + 2);
    wat_appendf(c->w,
        "(struct.new $LuaString (array.new_data $LuaArr $str_data "
        "(i32.const %zu) (i32.const %zu)))\n", sr.offset, sr.len);
    emit_indent(c, depth + 2);
    wat_appendf(c->w, "(i32.const %d)\n", e->line);
    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    emit_indent(c, depth); wat_append(c->w, ")\n");
    size_t mna = e->as.method_call.nargs;
    int has_mv = mna > 0 && is_multival_tail(e->as.method_call.args[mna - 1]);
    emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
    emit_indent(c, depth + 1); wat_append(c->w, "(call $merge_args\n");
    emit_indent(c, depth + 2);
    wat_append(c->w, "(array.new_fixed $ArgArr 1 (local.get $tmp_any))\n");
    if (mna == 0) {
        emit_indent(c, depth + 2); wat_append(c->w, "(global.get $g_empty_args)\n");
    } else if (!has_mv) {
        emit_indent(c, depth + 2);
        wat_appendf(c->w, "(array.new_fixed $ArgArr %zu\n", mna);
        for (size_t i = 0; i < mna; i++) emit_expr(c, e->as.method_call.args[i], depth + 3);
        emit_indent(c, depth + 2); wat_append(c->w, ")\n");
    } else {
        emit_args_array(c, e->as.method_call.args, mna, depth + 2);
    }
    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    emit_indent(c, depth); wat_append(c->w, ")\n");
    emit_tail_dispatch(c, e->line, depth);
}

/* Tail call: `return f(args)` / `return obj:m(args)` lowers to a
 * return_call_ref so deep recursion doesn't grow the wasm call stack. */
static void emit_tail_call(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL) {
        emit_tail_method_call(c, e, depth);
        return;
    }
    /* Stash the callee in its own local: $tmp_any can't be used here because
     * a method-call argument (e.g. `f(s:gmatch(...))`) reuses $tmp_any for
     * its receiver while we build the args array below, which would clobber
     * the callee. */
    emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_callee\n");
    emit_expr(c, e->as.call.callee, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
    emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
    emit_args_array(c, e->as.call.args, e->as.call.nargs, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
    emit_tail_dispatch(c, e->line, depth);
}

/* ----- function expression: build a closure -----
 * The upvalue array collects the parent's boxes per the function's
 * upvalue table.
 */
static void emit_function_expr(CG *c, const LuaFunc *fn, int depth) {
    emit_indent(c, depth);
    wat_append(c->w, "(struct.new $LuaClosure\n");
    emit_indent(c, depth + 1);
    wat_appendf(c->w, "(ref.func $user_%d)\n", fn->func_idx);
    if (fn->n_upvalues == 0) {
        emit_indent(c, depth + 1);
        wat_append(c->w, "(global.get $g_empty_upvals)\n");
    } else {
        emit_indent(c, depth + 1);
        wat_appendf(c->w, "(array.new_fixed $UpvalArr %d\n", fn->n_upvalues);
        for (int i = 0; i < fn->n_upvalues; i++) {
            UpvalueRef *u = &fn->upvalues[i];
            VarKind k = (u->src == UPVAL_FROM_LOCAL) ? VAR_LOCAL : VAR_UPVAL;
            emit_box_ref(c, k, u->idx, depth + 2);
        }
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    }
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* ----- table operations ----- */
static void emit_index_expr(CG *c, const Expr *e, int depth) {
    /* `t[k]`. Use the runtime $lua_index helper instead of an inline
     * (ref.cast (ref $LuaTable) …) so that strings transparently route
     * through the string library and other-typed receivers throw a
     * Lua-shaped error with a source line. */
    emit_indent(c, depth); wat_append(c->w, "(call $lua_index\n");
    emit_expr(c, e->as.index.table, depth + 1);
    emit_expr(c, e->as.index.key, depth + 1);
    emit_indent(c, depth + 1);
    wat_appendf(c->w, "(i32.const %d)\n", e->line);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

static void emit_table_ctor(CG *c, const Expr *e, int depth) {
    int n = e->as.table_ctor.n_entries;
    /* Wrap in a block so the constructor appears as a single folded
     * expression from outside (works inside array.new_fixed arg lists,
     * function calls, etc.) but uses stack-form internally to keep the
     * in-progress table on the operand stack across entries. */
    emit_indent(c, depth); wat_append(c->w, "(block (result anyref)\n");
    emit_indent(c, depth + 1); wat_append(c->w, "(call $tab_new)\n");
    int pos_idx = 1;
    /* If the final entry is positional AND a multi-value tail (call/vararg),
     * we splice all of its values rather than just taking the first. */
    int splice_last = (n > 0 &&
                       e->as.table_ctor.entries[n - 1].kind == TENT_POSITIONAL &&
                       is_multival_tail(e->as.table_ctor.entries[n - 1].value));
    int last_normal = splice_last ? n - 1 : n;
    for (int i = 0; i < last_normal; i++) {
        TableEntry *ent = &e->as.table_ctor.entries[i];
        emit_indent(c, depth + 1); wat_append(c->w, "local.tee $tmp_tab\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(ref.as_non_null (local.get $tmp_tab))\n");
        if (ent->kind == TENT_POSITIONAL) {
            emit_indent(c, depth + 1);
            wat_appendf(c->w, "(ref.i31 (i32.const %d))\n", pos_idx++);
        } else {
            emit_expr(c, ent->key, depth + 1);
        }
        emit_expr(c, ent->value, depth + 1);
        emit_indent(c, depth + 1); wat_append(c->w, "call $tab_set\n");
    }
    if (splice_last) {
        /* (call $tab_append_args (local.tee $tmp_tab) (i32.const pos_idx) <args>) */
        emit_indent(c, depth + 1); wat_append(c->w, "local.tee $tmp_tab\n");
        emit_indent(c, depth + 1); wat_append(c->w, "(call $tab_append_args\n");
        emit_indent(c, depth + 2); wat_append(c->w, "(ref.as_non_null (local.get $tmp_tab))\n");
        emit_indent(c, depth + 2); wat_appendf(c->w, "(i32.const %d)\n", pos_idx);
        emit_multival_array(c, e->as.table_ctor.entries[n - 1].value, depth + 2);
        emit_indent(c, depth + 1); wat_append(c->w, ")\n");
    }
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* ----- integer-specialization PoC (LUA2WASM_OPT_INT) ----- */

/* Is this slot a local proven to hold only integers (declared as i64)? */
static int slot_is_int(const CG *c, int slot) {
    if (!c->opt_int || !c->cur_is_int) return 0;
    if (slot < 0 || slot >= c->cur_n_locals) return 0;
    return c->cur_is_int[slot];
}

/* True iff `e` provably evaluates to a Lua integer and can be emitted as a
 * raw i64 via emit_int_expr. Conservative: only integer literals, i64 locals,
 * and integer-closed arithmetic over those. `/` and `^` are always float; `<<`
 * `>>` have non-trivial Lua semantics so are left to the generic path. */
static int expr_is_int(CG *c, const Expr *e) {
    if (!c->opt_int) return 0;
    switch (e->kind) {
    case EXPR_INT: return 1;
    case EXPR_VAR:
        return e->as.var.kind == VAR_LOCAL && slot_is_int(c, e->as.var.idx);
    case EXPR_BINOP:
        switch (e->as.binop.op) {
        case BIN_ADD: case BIN_SUB: case BIN_MUL:
        case BIN_FDIV: case BIN_MOD:
        case BIN_BAND: case BIN_BOR: case BIN_BXOR:
            return expr_is_int(c, e->as.binop.lhs) && expr_is_int(c, e->as.binop.rhs);
        default: return 0;
        }
    case EXPR_UNOP:
        return (e->as.unop.op == UN_NEG || e->as.unop.op == UN_BNOT)
            && expr_is_int(c, e->as.unop.operand);
    case EXPR_CALL: {
        /* A direct call to an int-returning function, callable with typed args
         * from here, yields a raw i64 (its $user_N_da1 returns i64). */
        const LuaFunc *K = direct_call_target(c, e);
        const FuncSig *sg = target_sig(c, K);
        return sg && sg->ret_ty == NT_INT && direct_args_typed_ok(c, e, K);
    }
    default: return 0;
    }
}

/* Emit `e` (which must satisfy expr_is_int) as a raw i64 on the wasm stack. */
static void emit_int_expr(CG *c, const Expr *e, int depth) {
    if (!c->ok) return;
    switch (e->kind) {
    case EXPR_INT:
        emit_indent(c, depth);
        wat_appendf(c->w, "(i64.const %lld)\n", (long long)e->as.i_val);
        return;
    case EXPR_VAR:
        emit_indent(c, depth);
        wat_appendf(c->w, "(local.get $L%d)\n", e->as.var.idx);
        return;
    case EXPR_UNOP:
        if (e->as.unop.op == UN_NEG) {
            emit_indent(c, depth); wat_append(c->w, "(i64.sub (i64.const 0)\n");
            emit_int_expr(c, e->as.unop.operand, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
        } else { /* UN_BNOT */
            emit_indent(c, depth); wat_append(c->w, "(i64.xor (i64.const -1)\n");
            emit_int_expr(c, e->as.unop.operand, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
        }
        return;
    case EXPR_BINOP: {
        const char *op = NULL, *fn = NULL;
        switch (e->as.binop.op) {
        case BIN_ADD: op = "i64.add"; break;
        case BIN_SUB: op = "i64.sub"; break;
        case BIN_MUL: op = "i64.mul"; break;
        case BIN_BAND: op = "i64.and"; break;
        case BIN_BOR:  op = "i64.or";  break;
        case BIN_BXOR: op = "i64.xor"; break;
        case BIN_FDIV: fn = "$idiv_floor"; break;
        case BIN_MOD:  fn = "$imod_floor"; break;
        default: break;
        }
        emit_indent(c, depth);
        if (fn) wat_appendf(c->w, "(call %s\n", fn);
        else    wat_appendf(c->w, "(%s\n", op);
        emit_int_expr(c, e->as.binop.lhs, depth + 1);
        emit_int_expr(c, e->as.binop.rhs, depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    case EXPR_CALL:
        /* Guarded by expr_is_int: a direct call to an int-returning function. */
        emit_typed_direct_call1(c, e, direct_call_target(c, e), depth);
        return;
    default:
        cg_error(c, "emit_int_expr on non-integer expression");
    }
}

/* Is this slot a local proven to hold only floats (declared as f64)? */
static int slot_is_float(const CG *c, int slot) {
    if (!c->opt_int || !c->cur_is_float) return 0;
    if (slot < 0 || slot >= c->cur_n_locals) return 0;
    return c->cur_is_float[slot];
}

/* True iff `e` provably evaluates to a Lua float and can be emitted as a raw
 * f64 via emit_float_expr. `/` is always float; `+ - *` are float when at
 * least one operand is float and the other is numeric (int promotes). `// % ^`
 * are left to the generic path for now. */
static int expr_is_float(CG *c, const Expr *e) {
    if (!c->opt_int) return 0;
    switch (e->kind) {
    case EXPR_FLOAT: return 1;
    case EXPR_VAR:
        return e->as.var.kind == VAR_LOCAL && slot_is_float(c, e->as.var.idx);
    case EXPR_BINOP: {
        const Expr *l = e->as.binop.lhs, *r = e->as.binop.rhs;
        int ln = expr_is_int(c, l) || expr_is_float(c, l);
        int rn = expr_is_int(c, r) || expr_is_float(c, r);
        switch (e->as.binop.op) {
        case BIN_DIV: return ln && rn;                               /* always float */
        case BIN_ADD: case BIN_SUB: case BIN_MUL:
            return ln && rn && (expr_is_float(c, l) || expr_is_float(c, r));
        default: return 0;
        }
    }
    case EXPR_UNOP:
        return e->as.unop.op == UN_NEG && expr_is_float(c, e->as.unop.operand);
    case EXPR_CALL: {
        /* A direct call to a float-returning function (its $user_N_da1 returns
         * f64), callable with typed args from here. */
        const LuaFunc *K = direct_call_target(c, e);
        const FuncSig *sg = target_sig(c, K);
        return sg && sg->ret_ty == NT_FLOAT && direct_args_typed_ok(c, e, K);
    }
    default: return 0;
    }
}

/* Emit a numeric (int- or float-typed) expression as a raw f64, converting an
 * integer operand with f64.convert_i64_s. */
static void emit_num_as_f64(CG *c, const Expr *e, int depth) {
    if (expr_is_float(c, e)) { emit_float_expr(c, e, depth); return; }
    /* must be integer-typed (the only other case expr_is_float admits) */
    emit_indent(c, depth); wat_append(c->w, "(f64.convert_i64_s\n");
    emit_int_expr(c, e, depth + 1);
    emit_indent(c, depth); wat_append(c->w, ")\n");
}

/* Emit `e` (which must satisfy expr_is_float) as a raw f64 on the wasm stack. */
static void emit_float_expr(CG *c, const Expr *e, int depth) {
    if (!c->ok) return;
    switch (e->kind) {
    case EXPR_FLOAT:
        emit_indent(c, depth);
        wat_appendf(c->w, "(f64.const %.17g)\n", e->as.f_val);
        return;
    case EXPR_VAR:
        emit_indent(c, depth);
        wat_appendf(c->w, "(local.get $L%d)\n", e->as.var.idx);
        return;
    case EXPR_UNOP: /* UN_NEG */
        emit_indent(c, depth); wat_append(c->w, "(f64.neg\n");
        emit_num_as_f64(c, e->as.unop.operand, depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    case EXPR_BINOP: {
        const char *op = "f64.add";
        switch (e->as.binop.op) {
        case BIN_ADD: op = "f64.add"; break;
        case BIN_SUB: op = "f64.sub"; break;
        case BIN_MUL: op = "f64.mul"; break;
        case BIN_DIV: op = "f64.div"; break;
        default: break;
        }
        emit_indent(c, depth); wat_appendf(c->w, "(%s\n", op);
        emit_num_as_f64(c, e->as.binop.lhs, depth + 1);
        emit_num_as_f64(c, e->as.binop.rhs, depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    case EXPR_CALL:
        /* Guarded by expr_is_float: a direct call to a float-returning function. */
        emit_typed_direct_call1(c, e, direct_call_target(c, e), depth);
        return;
    default:
        cg_error(c, "emit_float_expr on non-float expression");
    }
}

/* Walk one block, clearing out[] entries whose slot has any assignment that
 * isn't a clean single integer expression. Conservative and sound: a slot
 * stays set only if *every* assignment to it is provably integer. */
static void int_kill_block(CG *c, const Block *b, unsigned char *out, int *changed);

static void int_kill_stmt(CG *c, const Stmt *s, unsigned char *out, int *changed) {
    #define KILL(slot) do { int _s=(slot); if (_s>=0 && _s<c->cur_n_locals && out[_s]) { out[_s]=0; *changed=1; } } while (0)
    switch (s->kind) {
    case STMT_LOCAL: {
        int nn = s->as.local.n_names, nv = s->as.local.n_values;
        for (int j = 0; j < nn; j++) {
            int slot = s->as.local.local_idxs[j];
            if (nv == nn && expr_is_int(c, s->as.local.values[j])) continue;
            KILL(slot);
        }
        break;
    }
    case STMT_ASSIGN: {
        int nt = s->as.assign.n_targets, nv = s->as.assign.n_values;
        for (int j = 0; j < nt; j++) {
            AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind != TGT_VAR || t->as.var.kind != VAR_LOCAL) continue;
            /* Only a single-target single-value int store is specialized; the
             * multi-target path stores anyref, which an i64 slot can't hold. */
            if (nt == 1 && nv == 1 && expr_is_int(c, s->as.assign.values[0])) continue;
            KILL(t->as.var.idx);
        }
        break;
    }
    case STMT_FOR_NUM: {
        const Expr *st = s->as.for_num.step;
        if (!(expr_is_int(c, s->as.for_num.start)
              && expr_is_int(c, s->as.for_num.stop)
              && (st == NULL || expr_is_int(c, st))))
            KILL(s->as.for_num.local_idx);
        int_kill_block(c, &s->as.for_num.body, out, changed);
        break;
    }
    case STMT_FOR_GEN:
        for (int j = 0; j < s->as.for_gen.n_names; j++) KILL(s->as.for_gen.local_idxs[j]);
        int_kill_block(c, &s->as.for_gen.body, out, changed);
        break;
    case STMT_LOCAL_FUNC: KILL(s->as.local_func.local_idx); break;
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++)
            int_kill_block(c, &s->as.if_stmt.arms[a].body, out, changed);
        if (s->as.if_stmt.has_else) int_kill_block(c, &s->as.if_stmt.else_body, out, changed);
        break;
    case STMT_WHILE:  int_kill_block(c, &s->as.while_stmt.body, out, changed); break;
    case STMT_DO:     int_kill_block(c, &s->as.do_stmt.body,    out, changed); break;
    case STMT_REPEAT: int_kill_block(c, &s->as.repeat.body,     out, changed); break;
    default: break;
    }
    #undef KILL
}

static void int_kill_block(CG *c, const Block *b, unsigned char *out, int *changed) {
    for (size_t i = 0; i < b->count; i++) int_kill_stmt(c, b->items[i], out, changed);
}

/* Fill out[0..n_locals) with the integer-only slots of one function body.
 * Optimistic start (every non-param, non-captured slot is a candidate), then
 * fixpoint-remove any contradicted by an assignment. A non-NULL param_seed
 * (the typed direct entries $user_N_da/_da1) additionally seeds parameter slots
 * marked NT_INT, so an i64 parameter is unboxed in the body. During inference a
 * still-undetermined parameter (NT_UNSET) is *optimistically* seeded int so a
 * self-recursive call's argument (e.g. `n-1`) types as int instead of poisoning
 * the parameter to ANY before the external call sites are seen; emission only
 * ever passes finalized seeds (no NT_UNSET). */
static void compute_int_slots(CG *c, const Block *body, int n_locals, int n_params,
                              const unsigned char *captured, unsigned char *out,
                              const NumTy *param_seed) {
    for (int i = 0; i < n_locals; i++) {
        if (captured && captured[i]) { out[i] = 0; continue; }
        out[i] = (i >= n_params) ||
                 (param_seed && (param_seed[i] == NT_INT || param_seed[i] == NT_UNSET));
    }
    const unsigned char *saved = c->cur_is_int;
    int saved_n = c->cur_n_locals;
    c->cur_is_int = out;
    c->cur_n_locals = n_locals;
    int changed = 1;
    while (changed) { changed = 0; int_kill_block(c, body, out, &changed); }
    c->cur_is_int = saved;
    c->cur_n_locals = saved_n;
}

/* Float analog of int_kill_*. A slot stays float only if every assignment is a
 * float-typed expression. Numeric-for control vars are never float-specialized
 * (no f64 for-loop yet), so they are killed. Requires the final int bitmap. */
static void float_kill_block(CG *c, const Block *b, unsigned char *out, int *changed);

static void float_kill_stmt(CG *c, const Stmt *s, unsigned char *out, int *changed) {
    #define KILLF(slot) do { int _s=(slot); if (_s>=0 && _s<c->cur_n_locals && out[_s]) { out[_s]=0; *changed=1; } } while (0)
    switch (s->kind) {
    case STMT_LOCAL: {
        int nn = s->as.local.n_names, nv = s->as.local.n_values;
        for (int j = 0; j < nn; j++) {
            if (nv == nn && expr_is_float(c, s->as.local.values[j])) continue;
            KILLF(s->as.local.local_idxs[j]);
        }
        break;
    }
    case STMT_ASSIGN: {
        int nt = s->as.assign.n_targets, nv = s->as.assign.n_values;
        for (int j = 0; j < nt; j++) {
            AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind != TGT_VAR || t->as.var.kind != VAR_LOCAL) continue;
            if (nt == 1 && nv == 1 && expr_is_float(c, s->as.assign.values[0])) continue;
            KILLF(t->as.var.idx);
        }
        break;
    }
    case STMT_FOR_NUM:
        KILLF(s->as.for_num.local_idx);
        float_kill_block(c, &s->as.for_num.body, out, changed);
        break;
    case STMT_FOR_GEN:
        for (int j = 0; j < s->as.for_gen.n_names; j++) KILLF(s->as.for_gen.local_idxs[j]);
        float_kill_block(c, &s->as.for_gen.body, out, changed);
        break;
    case STMT_LOCAL_FUNC: KILLF(s->as.local_func.local_idx); break;
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++)
            float_kill_block(c, &s->as.if_stmt.arms[a].body, out, changed);
        if (s->as.if_stmt.has_else) float_kill_block(c, &s->as.if_stmt.else_body, out, changed);
        break;
    case STMT_WHILE:  float_kill_block(c, &s->as.while_stmt.body, out, changed); break;
    case STMT_DO:     float_kill_block(c, &s->as.do_stmt.body,    out, changed); break;
    case STMT_REPEAT: float_kill_block(c, &s->as.repeat.body,     out, changed); break;
    default: break;
    }
    #undef KILLF
}

static void float_kill_block(CG *c, const Block *b, unsigned char *out, int *changed) {
    for (size_t i = 0; i < b->count; i++) float_kill_stmt(c, b->items[i], out, changed);
}

/* Fill out[] with float-only slots. Run AFTER compute_int_slots (with the
 * final int bitmap live on c->cur_is_int, since expr_is_float consults
 * expr_is_int for mixed int/float operands). */
static void compute_float_slots(CG *c, const Block *body, int n_locals, int n_params,
                                const unsigned char *captured, unsigned char *out,
                                const NumTy *param_seed) {
    for (int i = 0; i < n_locals; i++) {
        if ((captured && captured[i]) || (c->cur_is_int && c->cur_is_int[i])) { out[i] = 0; continue; }
        out[i] = (i >= n_params) || (param_seed && param_seed[i] == NT_FLOAT);
    }
    const unsigned char *saved = c->cur_is_float;
    int saved_n = c->cur_n_locals;
    c->cur_is_float = out;
    c->cur_n_locals = n_locals;
    int changed = 1;
    while (changed) { changed = 0; float_kill_block(c, body, out, &changed); }
    c->cur_is_float = saved;
    c->cur_n_locals = saved_n;
}

/* Record which local slots are statically bound to a known function (lever 3). */
static void func_slot_walk(const Block *b, const LuaFunc **out,
                           unsigned char *reassigned, int n);
static void func_slot_walk_stmt(const Stmt *s, const LuaFunc **out,
                                unsigned char *reassigned, int n) {
    switch (s->kind) {
    case STMT_LOCAL_FUNC: {
        int sl = s->as.local_func.local_idx;
        if (sl >= 0 && sl < n) out[sl] = s->as.local_func.func;
        break;
    }
    case STMT_LOCAL:
        if (s->as.local.n_values == s->as.local.n_names)
            for (int j = 0; j < s->as.local.n_names; j++)
                if (s->as.local.values[j]->kind == EXPR_FUNCTION) {
                    int sl = s->as.local.local_idxs[j];
                    if (sl >= 0 && sl < n) out[sl] = s->as.local.values[j]->as.func_expr.func;
                }
        break;
    case STMT_ASSIGN:
        for (int j = 0; j < s->as.assign.n_targets; j++) {
            AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL
                && t->as.var.idx >= 0 && t->as.var.idx < n)
                reassigned[t->as.var.idx] = 1;
        }
        break;
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++)
            func_slot_walk(&s->as.if_stmt.arms[a].body, out, reassigned, n);
        if (s->as.if_stmt.has_else) func_slot_walk(&s->as.if_stmt.else_body, out, reassigned, n);
        break;
    case STMT_WHILE:   func_slot_walk(&s->as.while_stmt.body, out, reassigned, n); break;
    case STMT_DO:      func_slot_walk(&s->as.do_stmt.body,    out, reassigned, n); break;
    case STMT_REPEAT:  func_slot_walk(&s->as.repeat.body,     out, reassigned, n); break;
    case STMT_FOR_NUM: func_slot_walk(&s->as.for_num.body,    out, reassigned, n); break;
    case STMT_FOR_GEN: func_slot_walk(&s->as.for_gen.body,    out, reassigned, n); break;
    default: break;
    }
}
static void func_slot_walk(const Block *b, const LuaFunc **out,
                           unsigned char *reassigned, int n) {
    for (size_t i = 0; i < b->count; i++) func_slot_walk_stmt(b->items[i], out, reassigned, n);
}

/* ----- global function-binding maps (direct-call resolution) -----
 *
 * For every function (and main) record which LuaFunc each local slot and each
 * upvalue stably resolves to. A binding is stable iff the slot is never
 * reassigned — neither directly (an assignment to the local) nor through an
 * upvalue in any descendant closure. Captured slots are *kept* (unlike the old
 * per-body scan), so a self-recursive `local function f` — which captures itself
 * as an upvalue — is a direct-call target both inside its body (the upvalue) and
 * from its defining scope (the captured local). Reassignment via upvalue is what
 * the captured-exclusion used to guard against; we now check it precisely. */

typedef struct {
    const LuaFunc **slot_func;   /* [n_locals]  slot -> bound LuaFunc (or NULL) */
    unsigned char  *reass_local; /* [n_locals]  slot assigned somewhere in body */
    unsigned char  *reass_upval; /* [n_upvalues] upvalue assigned in body (or NULL) */
    int n_locals, n_upvalues;
} BindAccum;

static void bind_walk_block(const Block *b, BindAccum *a);
static void bind_walk_stmt(const Stmt *s, BindAccum *a) {
    switch (s->kind) {
    case STMT_LOCAL_FUNC: {
        int sl = s->as.local_func.local_idx;
        if (sl >= 0 && sl < a->n_locals) a->slot_func[sl] = s->as.local_func.func;
        break;
    }
    case STMT_LOCAL:
        if (s->as.local.n_values == s->as.local.n_names)
            for (int j = 0; j < s->as.local.n_names; j++)
                if (s->as.local.values[j]->kind == EXPR_FUNCTION) {
                    int sl = s->as.local.local_idxs[j];
                    if (sl >= 0 && sl < a->n_locals)
                        a->slot_func[sl] = s->as.local.values[j]->as.func_expr.func;
                }
        break;
    case STMT_ASSIGN:
        for (int j = 0; j < s->as.assign.n_targets; j++) {
            AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind != TGT_VAR) continue;
            if (t->as.var.kind == VAR_LOCAL && t->as.var.idx >= 0 && t->as.var.idx < a->n_locals)
                a->reass_local[t->as.var.idx] = 1;
            else if (t->as.var.kind == VAR_UPVAL && a->reass_upval
                     && t->as.var.idx >= 0 && t->as.var.idx < a->n_upvalues)
                a->reass_upval[t->as.var.idx] = 1;
        }
        break;
    case STMT_IF:
        for (size_t k = 0; k < s->as.if_stmt.narms; k++) bind_walk_block(&s->as.if_stmt.arms[k].body, a);
        if (s->as.if_stmt.has_else) bind_walk_block(&s->as.if_stmt.else_body, a);
        break;
    case STMT_WHILE:   bind_walk_block(&s->as.while_stmt.body, a); break;
    case STMT_DO:      bind_walk_block(&s->as.do_stmt.body,    a); break;
    case STMT_REPEAT:  bind_walk_block(&s->as.repeat.body,     a); break;
    case STMT_FOR_NUM: bind_walk_block(&s->as.for_num.body,    a); break;
    case STMT_FOR_GEN: bind_walk_block(&s->as.for_gen.body,    a); break;
    default: break; /* nested function literals are walked on their own row */
    }
}
static void bind_walk_block(const Block *b, BindAccum *a) {
    for (size_t i = 0; i < b->count; i++) bind_walk_stmt(b->items[i], a);
}

/* The slot_func map (and its length) for a given enclosing scope; func_idx == -1
 * is the main chunk. */
static const LuaFunc **bind_slot_map(CG *c, int func_idx, int *n_out) {
    if (func_idx == -1) { *n_out = c->pr->main_n_locals; return c->main_slot_func; }
    if (func_idx < 0 || func_idx >= c->n_sigs) { *n_out = 0; return NULL; }
    *n_out = c->pr->funcs.items[func_idx]->n_locals;
    return c->bind_slot[func_idx];
}

/* Trace upvalue u of function func_idx back to the (scope, local-slot) where it
 * originates. *of == -1 means the main chunk; *of == -2 means unresolvable. */
static void resolve_upval_origin(CG *c, int func_idx, int u, int *of, int *os) {
    const LuaFunc *F = c->pr->funcs.items[func_idx];
    if (!F->upvalues || u < 0 || u >= F->n_upvalues) { *of = -2; *os = -1; return; }
    UpvalueRef ref = F->upvalues[u];
    if (ref.src == UPVAL_FROM_LOCAL) { *of = F->parent_idx; *os = ref.idx; }
    else if (F->parent_idx >= 0)     resolve_upval_origin(c, F->parent_idx, ref.idx, of, os);
    else                             { *of = -2; *os = -1; }   /* main has no upvalues */
}

/* Build c->bind_slot / c->bind_upval / c->main_slot_func. */
static void compute_func_bindings(CG *c, const ParseResult *pr) {
    int n = (int)pr->funcs.count;
    c->bind_slot  = calloc(n ? n : 1, sizeof *c->bind_slot);
    c->bind_upval = calloc(n ? n : 1, sizeof *c->bind_upval);
    c->main_slot_func = calloc(pr->main_n_locals ? pr->main_n_locals : 1, sizeof(const LuaFunc *));
    unsigned char **reass_upval = calloc(n ? n : 1, sizeof *reass_upval);

    /* Pass 1: per-scope bindings; drop directly-reassigned local bindings. */
    {
        unsigned char *rl = calloc(pr->main_n_locals ? pr->main_n_locals : 1, 1);
        BindAccum a = { c->main_slot_func, rl, NULL, pr->main_n_locals, 0 };
        bind_walk_block(&pr->main_body, &a);
        for (int s = 0; s < pr->main_n_locals; s++) if (rl[s]) c->main_slot_func[s] = NULL;
        free(rl);
    }
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        c->bind_slot[f]  = calloc(F->n_locals ? F->n_locals : 1, sizeof(const LuaFunc *));
        c->bind_upval[f] = calloc(F->n_upvalues ? F->n_upvalues : 1, sizeof(const LuaFunc *));
        reass_upval[f]   = calloc(F->n_upvalues ? F->n_upvalues : 1, 1);
        unsigned char *rl = calloc(F->n_locals ? F->n_locals : 1, 1);
        BindAccum a = { c->bind_slot[f], rl, reass_upval[f], F->n_locals, F->n_upvalues };
        bind_walk_block(&F->body, &a);
        for (int s = 0; s < F->n_locals; s++) if (rl[s]) c->bind_slot[f][s] = NULL;
        free(rl);
    }

    /* Pass 2: a slot reassigned through an upvalue in any descendant is unstable
     * at its origin too. */
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        for (int u = 0; u < F->n_upvalues; u++) {
            if (!reass_upval[f][u]) continue;
            int of, os; resolve_upval_origin(c, f, u, &of, &os);
            int nn; const LuaFunc **m = bind_slot_map(c, of, &nn);
            if (m && os >= 0 && os < nn) m[os] = NULL;
        }
    }

    /* Pass 3: resolve each upvalue to its (now-finalized) bound function. */
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        for (int u = 0; u < F->n_upvalues; u++) {
            int of, os; resolve_upval_origin(c, f, u, &of, &os);
            int nn; const LuaFunc **m = bind_slot_map(c, of, &nn);
            c->bind_upval[f][u] = (m && os >= 0 && os < nn) ? m[os] : NULL;
        }
        free(reass_upval[f]);
    }
    free(reass_upval);
}

static void free_func_bindings(CG *c) {
    if (c->bind_slot)  for (int i = 0; i < c->n_sigs; i++) free((void *)c->bind_slot[i]);
    if (c->bind_upval) for (int i = 0; i < c->n_sigs; i++) free((void *)c->bind_upval[i]);
    free(c->bind_slot);  c->bind_slot = NULL;
    free(c->bind_upval); c->bind_upval = NULL;
    free(c->main_slot_func); c->main_slot_func = NULL;
}

/* ----- whole-program signature inference (param + return unboxing) -----
 *
 * A monotone fixpoint over all functions (and the main chunk). Each parameter
 * starts at NT_UNSET and is narrowed by meeting it with the argument type at
 * every direct-call site; each function's single-value return type is recomputed
 * from its body each round. The lattice only moves downward, so iteration
 * terminates. Reading not-yet-final values mid-fixpoint is sound for the same
 * reason the per-function int-slot fixpoint above is: contradictions propagate
 * and re-narrow on the next round.
 *
 * The inferred signature only types the dedicated $user_N_da/_da1 entries; a
 * call site uses them only when its arguments are typed-ok (direct_args_typed_ok),
 * otherwise it falls back to the fully generic path — so over-typing is never
 * unsound, just occasionally a missed fast path. */

static NumTy num_meet(NumTy a, NumTy b) {
    if (a == NT_UNSET) return b;
    if (b == NT_UNSET) return a;
    return a == b ? a : NT_ANY;   /* INT vs FLOAT (or any disagreement) -> ANY */
}

/* Does every path through the block end in a `return`? Conservative: only the
 * trailing statement is examined (an if/else both of whose arms always return,
 * a do-block, or a literal return). */
static int block_always_returns(const Block *b);
static int stmt_always_returns(const Stmt *s) {
    switch (s->kind) {
    case STMT_RETURN: return 1;
    case STMT_DO:     return block_always_returns(&s->as.do_stmt.body);
    case STMT_IF:
        if (!s->as.if_stmt.has_else) return 0;
        for (size_t a = 0; a < s->as.if_stmt.narms; a++)
            if (!block_always_returns(&s->as.if_stmt.arms[a].body)) return 0;
        return block_always_returns(&s->as.if_stmt.else_body);
    default: return 0;
    }
}
static int block_always_returns(const Block *b) {
    return b->count > 0 && stmt_always_returns(b->items[b->count - 1]);
}

/* Meet every return's value type into *acc (NT_UNSET is the identity). A return
 * that isn't a single numeric value, or that disagrees with another (int vs
 * float), folds *acc to NT_ANY. Skips nested functions. */
static void ret_scan_block(CG *c, const Block *b, NumTy *acc);
static void ret_scan_stmt(CG *c, const Stmt *s, NumTy *acc) {
    switch (s->kind) {
    case STMT_RETURN:
        *acc = num_meet(*acc, s->as.return_stmt.n_values == 1
                              ? expr_num_ty(c, s->as.return_stmt.values[0])
                              : NT_ANY);
        return;
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++)
            ret_scan_block(c, &s->as.if_stmt.arms[a].body, acc);
        if (s->as.if_stmt.has_else) ret_scan_block(c, &s->as.if_stmt.else_body, acc);
        return;
    case STMT_WHILE:   ret_scan_block(c, &s->as.while_stmt.body, acc); return;
    case STMT_DO:      ret_scan_block(c, &s->as.do_stmt.body,    acc); return;
    case STMT_REPEAT:  ret_scan_block(c, &s->as.repeat.body,     acc); return;
    case STMT_FOR_NUM: ret_scan_block(c, &s->as.for_num.body,    acc); return;
    case STMT_FOR_GEN: ret_scan_block(c, &s->as.for_gen.body,    acc); return;
    default: return;
    }
}
static void ret_scan_block(CG *c, const Block *b, NumTy *acc) {
    for (size_t i = 0; i < b->count; i++) ret_scan_stmt(c, b->items[i], acc);
}

/* Single-value return type of fn in the current context, or NT_ANY when the
 * function may fall through (return nil) or its returns aren't one shared
 * numeric type. */
static NumTy compute_ret_ty(CG *c, const LuaFunc *fn) {
    if (!block_always_returns(&fn->body)) return NT_ANY;
    NumTy acc = NT_UNSET;
    ret_scan_block(c, &fn->body, &acc);
    return acc == NT_UNSET ? NT_ANY : acc;   /* UNSET only if no returns at all */
}

/* Walk a body in the current context and, at each direct-call site, narrow the
 * callee's parameter types by meeting them with the argument types here. */
static void infer_sites_block(CG *c, const Block *b, int *changed);
static void infer_sites_expr(CG *c, const Expr *e, int *changed) {
    if (!e) return;
    switch (e->kind) {
    case EXPR_CALL: {
        infer_sites_expr(c, e->as.call.callee, changed);
        for (size_t i = 0; i < e->as.call.nargs; i++)
            infer_sites_expr(c, e->as.call.args[i], changed);
        const LuaFunc *K = direct_call_target(c, e);
        if (K && K->func_idx >= 0 && K->func_idx < c->n_sigs) {
            FuncSig *sg = &c->sigs[K->func_idx];
            sg->has_site = 1;
            for (size_t i = 0; i < e->as.call.nargs && (int)i < sg->n_params; i++) {
                if (sg->param_ty[i] == NT_ANY) continue;
                NumTy nw = num_meet(sg->param_ty[i], expr_num_ty(c, e->as.call.args[i]));
                if (nw != sg->param_ty[i]) { sg->param_ty[i] = nw; *changed = 1; }
            }
        }
        return;
    }
    case EXPR_METHOD_CALL:
        infer_sites_expr(c, e->as.method_call.recv, changed);
        for (size_t i = 0; i < e->as.method_call.nargs; i++)
            infer_sites_expr(c, e->as.method_call.args[i], changed);
        return;
    case EXPR_BINOP:
        infer_sites_expr(c, e->as.binop.lhs, changed);
        infer_sites_expr(c, e->as.binop.rhs, changed);
        return;
    case EXPR_UNOP: infer_sites_expr(c, e->as.unop.operand, changed); return;
    case EXPR_INDEX:
        infer_sites_expr(c, e->as.index.table, changed);
        infer_sites_expr(c, e->as.index.key, changed);
        return;
    case EXPR_TABLE:
        for (int i = 0; i < e->as.table_ctor.n_entries; i++) {
            infer_sites_expr(c, e->as.table_ctor.entries[i].key, changed);
            infer_sites_expr(c, e->as.table_ctor.entries[i].value, changed);
        }
        return;
    default: return; /* EXPR_FUNCTION bodies are walked on their own row */
    }
}
static void infer_sites_stmt(CG *c, const Stmt *s, int *changed) {
    switch (s->kind) {
    case STMT_LOCAL:
        for (int i = 0; i < s->as.local.n_values; i++) infer_sites_expr(c, s->as.local.values[i], changed);
        break;
    case STMT_ASSIGN:
        for (int i = 0; i < s->as.assign.n_targets; i++) {
            AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind == TGT_INDEX) {
                infer_sites_expr(c, t->as.index.table, changed);
                infer_sites_expr(c, t->as.index.key, changed);
            }
        }
        for (int i = 0; i < s->as.assign.n_values; i++) infer_sites_expr(c, s->as.assign.values[i], changed);
        break;
    case STMT_EXPR:   infer_sites_expr(c, s->as.expr_stmt.expr, changed); break;
    case STMT_RETURN:
        for (int i = 0; i < s->as.return_stmt.n_values; i++) infer_sites_expr(c, s->as.return_stmt.values[i], changed);
        break;
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++) {
            infer_sites_expr(c, s->as.if_stmt.arms[a].cond, changed);
            infer_sites_block(c, &s->as.if_stmt.arms[a].body, changed);
        }
        if (s->as.if_stmt.has_else) infer_sites_block(c, &s->as.if_stmt.else_body, changed);
        break;
    case STMT_WHILE:
        infer_sites_expr(c, s->as.while_stmt.cond, changed);
        infer_sites_block(c, &s->as.while_stmt.body, changed);
        break;
    case STMT_DO: infer_sites_block(c, &s->as.do_stmt.body, changed); break;
    case STMT_REPEAT:
        infer_sites_block(c, &s->as.repeat.body, changed);
        infer_sites_expr(c, s->as.repeat.cond, changed);
        break;
    case STMT_FOR_NUM:
        infer_sites_expr(c, s->as.for_num.start, changed);
        infer_sites_expr(c, s->as.for_num.stop, changed);
        if (s->as.for_num.step) infer_sites_expr(c, s->as.for_num.step, changed);
        infer_sites_block(c, &s->as.for_num.body, changed);
        break;
    case STMT_FOR_GEN:
        for (int i = 0; i < s->as.for_gen.n_exprs; i++) infer_sites_expr(c, s->as.for_gen.exprs[i], changed);
        infer_sites_block(c, &s->as.for_gen.body, changed);
        break;
    default: break; /* STMT_LOCAL_FUNC body walked on its own row */
    }
}
static void infer_sites_block(CG *c, const Block *b, int *changed) {
    for (size_t i = 0; i < b->count; i++) infer_sites_stmt(c, b->items[i], changed);
}

/* One fixpoint step for a single function/main body: rebuild its analysis
 * context from current signatures + the global binding maps, then narrow
 * callees' params and (for a real function) recompute its own return type.
 * func_idx == -1 is the main chunk. */
static void infer_step_body(CG *c, const Block *body, int n_locals, int n_params,
                            const unsigned char *captured, const NumTy *param_seed,
                            const LuaFunc *fn, int func_idx, int *changed) {
    const unsigned char *p_int = c->cur_is_int, *p_float = c->cur_is_float;
    const LuaFunc **p_fs = c->cur_func_slot, **p_uv = c->cur_upval_func;
    int p_nl = c->cur_n_locals, p_np = c->cur_n_params, p_fi = c->cur_func_idx;

    unsigned char *isint = calloc(n_locals ? n_locals : 1, 1);
    unsigned char *isfloat = calloc(n_locals ? n_locals : 1, 1);
    int nn;
    c->cur_func_slot = bind_slot_map(c, func_idx, &nn);
    c->cur_upval_func = func_idx >= 0 ? c->bind_upval[func_idx] : NULL;
    c->cur_func_idx = func_idx;
    c->cur_n_locals = n_locals;
    c->cur_n_params = n_params;
    compute_int_slots(c, body, n_locals, n_params, captured, isint, param_seed);
    c->cur_is_int = isint;
    compute_float_slots(c, body, n_locals, n_params, captured, isfloat, param_seed);
    c->cur_is_float = isfloat;

    infer_sites_block(c, body, changed);
    if (fn) {
        NumTy r = compute_ret_ty(c, fn);
        if (r != c->sigs[fn->func_idx].ret_ty) { c->sigs[fn->func_idx].ret_ty = r; *changed = 1; }
    }

    c->cur_is_int = p_int; c->cur_is_float = p_float; c->cur_func_slot = p_fs;
    c->cur_upval_func = p_uv; c->cur_n_locals = p_nl; c->cur_n_params = p_np;
    c->cur_func_idx = p_fi;
    free(isint); free(isfloat);
}

/* Allocate and infer c->sigs for every user function. */
static void infer_signatures(CG *c, const ParseResult *pr) {
    int n = (int)pr->funcs.count;
    c->n_sigs = n;
    c->sigs = calloc(n ? n : 1, sizeof *c->sigs);
    for (int i = 0; i < n; i++) {
        const LuaFunc *fn = pr->funcs.items[i];
        FuncSig *sg = &c->sigs[i];
        sg->n_params = fn->n_params;
        sg->ret_ty = NT_INT;            /* optimistic; narrows downward */
        sg->has_site = 0;
        sg->param_ty = fn->n_params ? calloc(fn->n_params, sizeof(NumTy)) : NULL;
        /* A parameter is eligible for unboxing only if it is never reassigned
         * and never captured; others are pinned to NT_ANY. */
        int nl = fn->n_locals;
        unsigned char *reassigned = calloc(nl ? nl : 1, 1);
        const LuaFunc **scratch = calloc(nl ? nl : 1, sizeof *scratch);
        func_slot_walk(&fn->body, scratch, reassigned, nl);
        for (int p = 0; p < fn->n_params; p++) {
            int pinned = reassigned[p] || (fn->captured && fn->captured[p]);
            sg->param_ty[p] = pinned ? NT_ANY : NT_UNSET;  /* narrowed by sites */
        }
        free(reassigned); free(scratch);
    }

    int changed = 1;
    while (changed) {
        changed = 0;
        for (int i = 0; i < n; i++) {
            const LuaFunc *fn = pr->funcs.items[i];
            infer_step_body(c, &fn->body, fn->n_locals, fn->n_params, fn->captured,
                            c->sigs[i].param_ty, fn, i, &changed);
        }
        infer_step_body(c, &pr->main_body, pr->main_n_locals, 0, pr->main_captured,
                        NULL, NULL, -1, &changed);
    }

    /* Finalize: a parameter with no narrowing evidence (NT_UNSET) becomes ANY,
     * and a function nothing direct-calls keeps its (dead) entries fully boxed —
     * matching the pre-unboxing output and avoiding stray unreachable entries. */
    for (int i = 0; i < n; i++) {
        FuncSig *sg = &c->sigs[i];
        if (!sg->has_site) {
            for (int p = 0; p < sg->n_params; p++) sg->param_ty[p] = NT_ANY;
            sg->ret_ty = NT_ANY;
        } else {
            for (int p = 0; p < sg->n_params; p++)
                if (sg->param_ty[p] == NT_UNSET) sg->param_ty[p] = NT_ANY;
        }
    }
}

static void free_signatures(CG *c) {
    if (!c->sigs) return;
    for (int i = 0; i < c->n_sigs; i++) free(c->sigs[i].param_ty);
    free(c->sigs);
    c->sigs = NULL;
    c->n_sigs = 0;
}

/* ----- main expression dispatch ----- */
static void emit_expr(CG *c, const Expr *e, int depth) {
    if (!c->ok) return;
    /* Integer-specialized value used in a Lua-value (anyref) context: emit the
     * unboxed i64 and box it. EXPR_INT keeps its existing path. */
    if (c->opt_int && e->kind != EXPR_INT && expr_is_int(c, e)) {
        emit_indent(c, depth); wat_append(c->w, "(call $make_int\n");
        emit_int_expr(c, e, depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    if (c->opt_int && e->kind != EXPR_FLOAT && expr_is_float(c, e)) {
        emit_indent(c, depth); wat_append(c->w, "(call $make_float\n");
        emit_float_expr(c, e, depth + 1);
        emit_indent(c, depth); wat_append(c->w, ")\n");
        return;
    }
    switch (e->kind) {
        case EXPR_NIL:
            emit_indent(c, depth); wat_append(c->w, "(ref.null any)\n"); break;
        case EXPR_TRUE:
            emit_indent(c, depth); wat_append(c->w, "(global.get $g_true)\n"); break;
        case EXPR_FALSE:
            emit_indent(c, depth); wat_append(c->w, "(global.get $g_false)\n"); break;
        case EXPR_INT:    emit_int_literal(c, e->as.i_val, depth); break;
        case EXPR_FLOAT:  emit_float_literal(c, e->as.f_val, depth); break;
        case EXPR_STRING: emit_string_literal(c, e->as.s.bytes, e->as.s.len, depth); break;
        case EXPR_VAR:    emit_var_read(c, e->as.var.kind, e->as.var.idx, depth); break;
        case EXPR_CALL:   emit_call(c, e, depth); break;
        case EXPR_BINOP:  emit_binop(c, e, depth); break;
        case EXPR_UNOP:   emit_unop(c, e, depth); break;
        case EXPR_FUNCTION: emit_function_expr(c, e->as.func_expr.func, depth); break;
        case EXPR_INDEX:  emit_index_expr(c, e, depth); break;
        case EXPR_TABLE:  emit_table_ctor(c, e, depth); break;
        case EXPR_METHOD_CALL: {
            /* Single-value context: wrap in $args_first. */
            emit_indent(c, depth); wat_append(c->w, "(call $args_first\n");
            emit_call_array(c, e, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            break;
        }
        case EXPR_VARARG:
            emit_indent(c, depth);
            wat_append(c->w,
                "(call $args_first (local.get $varargs))\n");
            break;
    }
}

/* Helper: emit code that pushes the i-th distributed value of a multi-value
 * binding/assignment.
 *
 *   n_values  = number of source expressions
 *   values    = those expressions
 *   last_call = nonzero iff values[n_values-1] is a CALL whose array result
 *               we want to splice in. The array is already in $tmp_args.
 *   i         = which target index we're filling (0-based)
 */
static void emit_distributed_value(CG *c, int i, int n_values, Expr **values,
                                   int last_call, int depth) {
    if (i < n_values - 1) {
        /* Plain expression at position i (single value). */
        emit_expr(c, values[i], depth);
        return;
    }
    if (i == n_values - 1) {
        if (last_call) {
            /* The trailing call. Take its first result. */
            emit_indent(c, depth);
            wat_append(c->w,
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0))\n");
        } else {
            emit_expr(c, values[i], depth);
        }
        return;
    }
    /* i > n_values - 1: only reachable if last_call (extra values from call) */
    if (last_call) {
        emit_indent(c, depth);
        wat_appendf(c->w,
            "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const %d))\n",
            i - (n_values - 1));
    } else {
        emit_indent(c, depth); wat_append(c->w, "(ref.null any)\n");
    }
}

/* ----- statements ----- */
static void emit_stmt(CG *c, const Stmt *s, int depth) {
    if (!c->ok) return;
    switch (s->kind) {
        case STMT_LOCAL: {
            int n_names = s->as.local.n_names;
            int n_values = s->as.local.n_values;
            int last_call = (n_values > 0 &&
                             is_multival_tail(s->as.local.values[n_values - 1]));
            if (last_call) {
                emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
                emit_multival_array(c, s->as.local.values[n_values - 1], depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            for (int i = 0; i < n_names; i++) {
                int slot = s->as.local.local_idxs[i];
                if (slot_is_int(c, slot)) {
                    /* i64 slot: analysis guarantees a matching single int value. */
                    emit_indent(c, depth);
                    wat_appendf(c->w, "(local.set $L%d\n", slot);
                    emit_int_expr(c, s->as.local.values[i], depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                    continue;
                }
                if (slot_is_float(c, slot)) {
                    emit_indent(c, depth);
                    wat_appendf(c->w, "(local.set $L%d\n", slot);
                    emit_float_expr(c, s->as.local.values[i], depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                    continue;
                }
                int boxed = slot_is_boxed(c, slot);
                emit_indent(c, depth);
                if (boxed) {
                    wat_appendf(c->w, "(local.set $L%d (struct.new $Box\n", slot);
                } else {
                    wat_appendf(c->w, "(local.set $L%d\n", slot);
                }
                if (n_values == 0) {
                    emit_indent(c, depth + 1); wat_append(c->w, "(ref.null any)\n");
                } else {
                    emit_distributed_value(c, i, n_values, s->as.local.values,
                                           last_call, depth + 1);
                }
                emit_indent(c, depth);
                wat_append(c->w, boxed ? "))\n" : ")\n");
            }
            break;
        }

        case STMT_ASSIGN: {
            int n_targets = s->as.assign.n_targets;
            int n_values = s->as.assign.n_values;
            int last_call = (n_values > 0 &&
                             is_multival_tail(s->as.assign.values[n_values - 1]));
            if (n_targets == 1) {
                AssignTarget *t = &s->as.assign.targets[0];
                if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL
                    && slot_is_int(c, t->as.var.idx)) {
                    emit_indent(c, depth);
                    wat_appendf(c->w, "(local.set $L%d\n", t->as.var.idx);
                    emit_int_expr(c, s->as.assign.values[0], depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                    break;
                }
                if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL
                    && slot_is_float(c, t->as.var.idx)) {
                    emit_indent(c, depth);
                    wat_appendf(c->w, "(local.set $L%d\n", t->as.var.idx);
                    emit_float_expr(c, s->as.assign.values[0], depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                    break;
                }
                emit_target_open(c, t, depth);
                if (last_call) {
                    emit_indent(c, depth + 1); wat_append(c->w, "(call $args_first\n");
                    emit_multival_array(c, s->as.assign.values[0], depth + 2);
                    emit_indent(c, depth + 1); wat_append(c->w, ")\n");
                } else {
                    emit_expr(c, s->as.assign.values[0], depth + 1);
                }
                emit_target_close(c, t, depth);
                break;
            }
            /* Multi-target. Lua evaluates every LHS table/key sub-expression
             * and every RHS value *before* any store, then stores right-to-
             * left (so a repeated target keeps its leftmost value, matching
             * reference). Concretely: `i, t[i] = i+1, 99` must capture t[i]'s
             * index before i is reassigned, and `g.a, g.b, g.a = 1, 2, 3`
             * must leave g.a == 1.
             *
             * Pre-evaluate index targets' table+key into parallel arrays
             * (left-to-right); plain var targets have a static address and
             * need no pre-eval, so we skip the arrays entirely when every
             * target is a variable. */
            (void)last_call;
            int has_index = 0;
            for (int i = 0; i < n_targets; i++)
                if (s->as.assign.targets[i].kind != TGT_VAR) { has_index = 1; break; }
            if (has_index) {
                emit_indent(c, depth);
                wat_appendf(c->w,
                    "(local.set $tmp_lhs_t (array.new $ArgArr (ref.null any) "
                    "(i32.const %d)))\n", n_targets);
                emit_indent(c, depth);
                wat_appendf(c->w,
                    "(local.set $tmp_lhs_k (array.new $ArgArr (ref.null any) "
                    "(i32.const %d)))\n", n_targets);
                for (int i = 0; i < n_targets; i++) {
                    AssignTarget *t = &s->as.assign.targets[i];
                    if (t->kind == TGT_VAR) continue;
                    emit_indent(c, depth);
                    wat_appendf(c->w,
                        "(array.set $ArgArr (ref.as_non_null (local.get $tmp_lhs_t)) "
                        "(i32.const %d)\n", i);
                    emit_expr(c, t->as.index.table, depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                    emit_indent(c, depth);
                    wat_appendf(c->w,
                        "(array.set $ArgArr (ref.as_non_null (local.get $tmp_lhs_k)) "
                        "(i32.const %d)\n", i);
                    emit_expr(c, t->as.index.key, depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                }
            }
            emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
            emit_args_array(c, s->as.assign.values, n_values, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            for (int i = n_targets - 1; i >= 0; i--) {
                AssignTarget *t = &s->as.assign.targets[i];
                if (t->kind == TGT_VAR) {
                    emit_target_open(c, t, depth);
                    emit_indent(c, depth + 1);
                    wat_appendf(c->w,
                        "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                        "(i32.const %d))\n", i);
                    emit_target_close(c, t, depth);
                } else {
                    /* index target: store via pre-evaluated table+key so
                     * __newindex still fires (matches emit_target_open). */
                    emit_indent(c, depth); wat_append(c->w, "(call $lua_tabset\n");
                    emit_indent(c, depth + 1);
                    wat_appendf(c->w,
                        "(array.get $ArgArr (ref.as_non_null (local.get $tmp_lhs_t)) "
                        "(i32.const %d))\n", i);
                    emit_indent(c, depth + 1);
                    wat_appendf(c->w,
                        "(array.get $ArgArr (ref.as_non_null (local.get $tmp_lhs_k)) "
                        "(i32.const %d))\n", i);
                    emit_indent(c, depth + 1);
                    wat_appendf(c->w,
                        "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                        "(i32.const %d))\n", i);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                }
            }
            break;
        }

        case STMT_EXPR:
            /* Call as statement: get array, drop it. */
            emit_call_array(c, s->as.expr_stmt.expr, depth);
            emit_indent(c, depth); wat_append(c->w, "drop\n");
            break;

        case STMT_DO:
            emit_block(c, &s->as.do_stmt.body, depth);
            break;

        case STMT_RETURN: {
            int n_values = s->as.return_stmt.n_values;
            if (c->in_main) {
                /* $main is exported with no result, so the chunk's return
                 * value can't be surfaced to the host — but we still have
                 * to evaluate the expressions so their side effects fire
                 * (e.g. `return print("hi")`). Drop each result after
                 * evaluation, then exit. */
                for (int i = 0; i < n_values; i++) {
                    emit_expr(c, s->as.return_stmt.values[i], depth);
                    emit_indent(c, depth); wat_append(c->w, "drop\n");
                }
                emit_indent(c, depth); wat_append(c->w, "return\n");
                break;
            }
            if (c->ret_single) {
                /* Single-value-return entry ($user_N_da1): produce exactly one
                 * value of the entry's result type. A numeric ret_ty was inferred
                 * only when every return is a single numeric value, so emit it
                 * raw (i64/f64). */
                if ((c->cur_ret_ty == NT_INT || c->cur_ret_ty == NT_FLOAT) && n_values == 1) {
                    emit_indent(c, depth); wat_append(c->w, "(return\n");
                    if (c->cur_ret_ty == NT_INT) emit_int_expr(c, s->as.return_stmt.values[0], depth + 1);
                    else                         emit_num_as_f64(c, s->as.return_stmt.values[0], depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                    break;
                }
                /* ret_ty == ANY: produce a single anyref. A non-vararg body never
                 * uses `...`, so a lone multi-value tail here is a call, adjusted
                 * to one by emit_expr. Extra return values still evaluate (side
                 * effects), in order. */
                if (n_values == 0) {
                    emit_indent(c, depth); wat_append(c->w, "(return (ref.null any))\n");
                } else if (n_values == 1) {
                    emit_indent(c, depth); wat_append(c->w, "(return\n");
                    emit_expr(c, s->as.return_stmt.values[0], depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                } else {
                    emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_any\n");
                    emit_expr(c, s->as.return_stmt.values[0], depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                    for (int i = 1; i < n_values; i++) {
                        emit_expr(c, s->as.return_stmt.values[i], depth);
                        emit_indent(c, depth); wat_append(c->w, "drop\n");
                    }
                    emit_indent(c, depth); wat_append(c->w, "(return (local.get $tmp_any))\n");
                }
                break;
            }
            /* Tail-call optimization: exactly `return f(args)` or
             * `return obj:m(args)` (not parenthesized, which forces adjust-to-
             * one and so isn't a tail call). */
            if (n_values == 1 && !s->as.return_stmt.values[0]->paren
                && (s->as.return_stmt.values[0]->kind == EXPR_CALL
                    || s->as.return_stmt.values[0]->kind == EXPR_METHOD_CALL)) {
                emit_tail_call(c, s->as.return_stmt.values[0], depth);
                break;
            }
            /* `return f(), x, ...` and similar: build the result array. A lone
             * multi-value tail (a single call/vararg) returns its array as-is. */
            if (n_values == 1 && is_multival_tail(s->as.return_stmt.values[0])) {
                emit_multival_array(c, s->as.return_stmt.values[0], depth);
            } else {
                emit_args_array(c, s->as.return_stmt.values, n_values, depth);
            }
            emit_indent(c, depth); wat_append(c->w, "return\n");
            break;
        }

        case STMT_WHILE: {
            int label = c->next_label++;
            if (!push_break_label(c, label)) break;
            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            emit_expr(c, s->as.while_stmt.cond, depth + 2);
            emit_indent(c, depth + 2); wat_append(c->w, "(call $lua_truthy)\n");
            emit_indent(c, depth + 2); wat_append(c->w, "i32.eqz\n");
            emit_indent(c, depth + 2); wat_appendf(c->w, "br_if $brk_%d\n", label);
            emit_block(c, &s->as.while_stmt.body, depth + 2);
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            c->break_depth--;
            break;
        }

        case STMT_REPEAT: {
            int label = c->next_label++;
            if (!push_break_label(c, label)) break;
            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            emit_block(c, &s->as.repeat.body, depth + 2);
            emit_expr(c, s->as.repeat.cond, depth + 2);
            emit_indent(c, depth + 2); wat_append(c->w, "(call $lua_truthy)\n");
            emit_indent(c, depth + 2); wat_append(c->w, "i32.eqz\n");
            emit_indent(c, depth + 2); wat_appendf(c->w, "br_if $cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            c->break_depth--;
            break;
        }

        case STMT_BREAK: {
            if (c->break_depth == 0) {
                cg_error(c, "break outside loop"); break;
            }
            int label = c->break_labels[c->break_depth - 1];
            emit_indent(c, depth);
            wat_appendf(c->w, "br $brk_%d\n", label);
            break;
        }

        case STMT_GOTO: {
            /* Dispatch lowering: set the target block's $next, then re-enter
             * its dispatch loop. The local and label are function-scoped, so
             * this works from inside arbitrarily nested blocks/loops. */
            emit_indent(c, depth);
            wat_appendf(c->w, "(local.set $next_%d (i32.const %d))\n",
                s->as.label.block_dispatch_id, s->as.label.target_segment_idx);
            emit_indent(c, depth);
            wat_appendf(c->w, "(br $dispatch_%d)\n", s->as.label.block_dispatch_id);
            break;
        }

        case STMT_LABEL:
            /* Wrappers are emitted by emit_block; the label statement
             * itself produces no code at its position. */
            break;

        case STMT_FOR_NUM: {
            int label = c->next_label++;
            if (!push_break_label(c, label)) break;
            int slot = s->as.for_num.local_idx;
            /* Integer-specialized loop: control var + bounds are i64, the
             * counter is an unboxed i64 slot, no per-iteration boxing or
             * generic-helper calls. The analysis only marks the slot int when
             * start/stop/step are all integer and the var isn't captured. */
            if (slot_is_int(c, slot)) {
                int fd = c->for_depth;
                const Expr *st = s->as.for_num.step;
                char step_s[40];
                int sign;   /* +1/-1 known at compile time; 0 = runtime */
                if (!st) { snprintf(step_s, sizeof step_s, "(i64.const 1)"); sign = 1; }
                else if (st->kind == EXPR_INT && st->as.i_val != 0) {
                    snprintf(step_s, sizeof step_s, "(i64.const %lld)", (long long)st->as.i_val);
                    sign = st->as.i_val > 0 ? 1 : -1;
                } else { snprintf(step_s, sizeof step_s, "(local.get $ifor_step_%d)", fd); sign = 0; }
                emit_indent(c, depth); wat_appendf(c->w, "(local.set $L%d\n", slot);
                emit_int_expr(c, s->as.for_num.start, depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
                emit_indent(c, depth); wat_appendf(c->w, "(local.set $ifor_stop_%d\n", fd);
                emit_int_expr(c, s->as.for_num.stop, depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
                if (sign == 0) {
                    emit_indent(c, depth); wat_appendf(c->w, "(local.set $ifor_step_%d\n", fd);
                    emit_int_expr(c, st, depth + 1);
                    emit_indent(c, depth); wat_append(c->w, ")\n");
                    emit_indent(c, depth);
                    wat_appendf(c->w, "(if (i64.eqz %s) (then (call $throw_lit (i32.const 75) (i32.const 18))))\n", step_s);
                }
                emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
                emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
                emit_indent(c, depth + 2);
                if (sign == 1)
                    wat_appendf(c->w, "(br_if $brk_%d (i64.gt_s (local.get $L%d) (local.get $ifor_stop_%d)))\n", label, slot, fd);
                else if (sign == -1)
                    wat_appendf(c->w, "(br_if $brk_%d (i64.lt_s (local.get $L%d) (local.get $ifor_stop_%d)))\n", label, slot, fd);
                else
                    wat_appendf(c->w,
                        "(if (i64.gt_s %s (i64.const 0)) (then (br_if $brk_%d (i64.gt_s (local.get $L%d) (local.get $ifor_stop_%d)))) (else (br_if $brk_%d (i64.lt_s (local.get $L%d) (local.get $ifor_stop_%d)))))\n",
                        step_s, label, slot, fd, label, slot, fd);
                c->for_depth++;
                emit_block(c, &s->as.for_num.body, depth + 2);
                c->for_depth--;
                emit_indent(c, depth + 2);
                wat_appendf(c->w, "(local.set $ifor_next_%d (i64.add (local.get $L%d) %s))\n", fd, slot, step_s);
                emit_indent(c, depth + 2);
                if (sign == 1)
                    wat_appendf(c->w, "(br_if $brk_%d (i64.lt_s (local.get $ifor_next_%d) (local.get $L%d)))\n", label, fd, slot);
                else if (sign == -1)
                    wat_appendf(c->w, "(br_if $brk_%d (i64.gt_s (local.get $ifor_next_%d) (local.get $L%d)))\n", label, fd, slot);
                else
                    wat_appendf(c->w,
                        "(if (i64.gt_s %s (i64.const 0)) (then (br_if $brk_%d (i64.lt_s (local.get $ifor_next_%d) (local.get $L%d)))) (else (br_if $brk_%d (i64.gt_s (local.get $ifor_next_%d) (local.get $L%d)))))\n",
                        step_s, label, fd, slot, label, fd, slot);
                emit_indent(c, depth + 2);
                wat_appendf(c->w, "(local.set $L%d (local.get $ifor_next_%d))\n", slot, fd);
                emit_indent(c, depth + 2); wat_appendf(c->w, "br $cont_%d\n", label);
                emit_indent(c, depth + 1); wat_append(c->w, ")\n");
                emit_indent(c, depth);     wat_append(c->w, ")\n");
                c->break_depth--;
                break;
            }
            int boxed = slot_is_boxed(c, slot);
            /* Per-nesting-level scratch so an inner for-loop can't clobber
             * this loop's stop/step. */
            int fd = c->for_depth;
            char f_stop[24], f_step[24], f_next[24], f_cur[24];
            snprintf(f_stop, sizeof f_stop, "$for_stop_%d", fd);
            snprintf(f_step, sizeof f_step, "$for_step_%d", fd);
            snprintf(f_next, sizeof f_next, "$for_next_%d", fd);
            snprintf(f_cur,  sizeof f_cur,  "$for_cur_%d",  fd);
            /* The running counter lives in a scratch local; stash stop/step
             * alongside. When the control variable is captured (boxed), the
             * counter must stay separate from the user-visible $Box so that
             * each iteration can bind a FRESH box (Lua 5.4+: the loop
             * variable is a new local per iteration, so closures capture
             * distinct values). When it isn't captured the slot holds the
             * value directly and doubles as the counter. */
            emit_indent(c, depth);
            if (boxed) {
                wat_appendf(c->w, "(local.set %s\n", f_cur);
            } else {
                wat_appendf(c->w, "(local.set $L%d\n", slot);
            }
            emit_expr(c, s->as.for_num.start, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            emit_indent(c, depth); wat_appendf(c->w, "(local.set %s\n", f_stop);
            emit_expr(c, s->as.for_num.stop, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            emit_indent(c, depth); wat_appendf(c->w, "(local.set %s\n", f_step);
            if (s->as.for_num.step) {
                emit_expr(c, s->as.for_num.step, depth + 1);
            } else {
                emit_indent(c, depth + 1); wat_append(c->w, "(ref.i31 (i32.const 1))\n");
            }
            emit_indent(c, depth); wat_append(c->w, ")\n");
            emit_indent(c, depth);
            wat_appendf(c->w, "(call $for_check_step (local.get %s))\n", f_step);
            /* Settle the control variable's type up front: if init or step is
             * a float the whole loop is float (Lua 5.4+). counter_loc is the
             * local that holds the running value. */
            char counter_loc[24];
            if (boxed) snprintf(counter_loc, sizeof counter_loc, "%s", f_cur);
            else       snprintf(counter_loc, sizeof counter_loc, "$L%d", slot);
            emit_indent(c, depth);
            wat_appendf(c->w,
                "(local.set %s (call $for_coerce (local.get %s) (local.get %s)))\n",
                counter_loc, counter_loc, f_step);
            emit_indent(c, depth);
            wat_appendf(c->w,
                "(local.set %s (call $for_coerce (local.get %s) (local.get %s)))\n",
                f_step, f_step, counter_loc);

            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            /* terminate? */
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "(if (call $for_step_positive (local.get %s))\n", f_step);
            emit_indent(c, depth + 2); wat_append(c->w, "  (then\n");
            char load_buf[80];
            if (boxed) snprintf(load_buf, sizeof(load_buf), "(local.get %s)", f_cur);
            else       snprintf(load_buf, sizeof(load_buf), "(local.get $L%d)", slot);
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "    (br_if $brk_%d (i32.eqz (call $num_le\n"
                "      %s\n"
                "      (local.get %s)))))\n", label, load_buf, f_stop);
            emit_indent(c, depth + 2); wat_append(c->w, "  (else\n");
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "    (br_if $brk_%d (i32.eqz (call $num_le\n"
                "      (local.get %s)\n"
                "      %s)))))\n", label, f_stop, load_buf);
            /* Fresh per-iteration binding for a captured control variable. */
            if (boxed) {
                emit_indent(c, depth + 2);
                wat_appendf(c->w,
                    "(local.set $L%d (struct.new $Box %s))\n", slot, load_buf);
            }
            /* body */
            c->for_depth++;
            emit_block(c, &s->as.for_num.body, depth + 2);
            c->for_depth--;
            /* i = i + step, but stop if the integer addition wrapped past the
             * representable range (Lua 5.4 numeric-for overflow semantics) —
             * otherwise `for i = maxinteger-2, maxinteger` would loop forever. */
            emit_indent(c, depth + 2);
            wat_appendf(c->w, "(local.set %s (call $lua_add %s (local.get %s)))\n",
                        f_next, load_buf, f_step);
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "(br_if $brk_%d (call $for_overflowed %s (local.get %s) "
                "(local.get %s)))\n", label, load_buf, f_step, f_next);
            emit_indent(c, depth + 2);
            if (boxed) {
                wat_appendf(c->w,
                    "(local.set %s (local.get %s))\n", f_cur, f_next);
            } else {
                wat_appendf(c->w,
                    "(local.set $L%d (local.get %s))\n", slot, f_next);
            }
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            c->break_depth--;
            break;
        }

        case STMT_FOR_GEN: {
            /* Generic for: `for v1[, v2, ...] in iter [, state [, init]] do body end`.
             * Evaluate the expr_list into ($for_iter_any, $for_state, $for_k),
             * then loop: call iter(state, k); if first result is nil, break;
             * otherwise bind v1..vN to results, set k = result[0]. */
            int label = c->next_label++;
            if (!push_break_label(c, label)) break;
            /* Per-nesting-level iterator state so an inner for-loop can't
             * clobber this loop's iterator/state/control key. ($tmp_args is
             * recomputed each iteration, so it stays function-shared.) */
            int fd = c->for_depth;
            char f_iter[24], f_state[24], f_k[24];
            snprintf(f_iter, sizeof f_iter, "$for_iter_%d", fd);
            snprintf(f_state, sizeof f_state, "$for_state_%d", fd);
            snprintf(f_k, sizeof f_k, "$for_k_%d", fd);
            int n_exprs = s->as.for_gen.n_exprs;
            emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
            emit_args_array(c, s->as.for_gen.exprs, n_exprs, depth + 1);
            emit_indent(c, depth); wat_append(c->w, ")\n");
            /* iter = args[0]; state = args[1]; k = args[2]. */
            emit_indent(c, depth); wat_appendf(c->w,
                "(local.set %s "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0)))\n", f_iter);
            emit_indent(c, depth); wat_appendf(c->w,
                "(local.set %s "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 1)))\n", f_state);
            emit_indent(c, depth); wat_appendf(c->w,
                "(local.set %s "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 2)))\n", f_k);

            /* Pre-allocate boxes (or just nil-init the local) per loop var. */
            for (int i = 0; i < s->as.for_gen.n_names; i++) {
                int li = s->as.for_gen.local_idxs[i];
                emit_indent(c, depth);
                if (slot_is_boxed(c, li)) {
                    wat_appendf(c->w,
                        "(local.set $L%d (struct.new $Box (ref.null any)))\n", li);
                } else {
                    wat_appendf(c->w, "(local.set $L%d (ref.null any))\n", li);
                }
            }

            emit_indent(c, depth); wat_appendf(c->w, "(block $brk_%d\n", label);
            emit_indent(c, depth + 1); wat_appendf(c->w, "(loop $cont_%d\n", label);
            /* Call iter(state, k). The iterator can be any callable (a
             * closure, or a table with __call) — go through $lua_call_any
             * so a wrong type produces a typed error instead of a trap. */
            emit_indent(c, depth + 2); wat_append(c->w, "(local.set $tmp_args\n");
            emit_indent(c, depth + 3); wat_append(c->w, "(call $lua_call_any\n");
            emit_indent(c, depth + 4); wat_appendf(c->w, "(local.get %s)\n", f_iter);
            emit_indent(c, depth + 4);
            wat_appendf(c->w,
                "(array.new_fixed $ArgArr 2 (local.get %s) (local.get %s))\n", f_state, f_k);
            emit_indent(c, depth + 4);
            wat_appendf(c->w, "(i32.const %d)\n", s->line);
            emit_indent(c, depth + 3); wat_append(c->w, ")\n");
            emit_indent(c, depth + 2); wat_append(c->w, ")\n");
            /* terminate if results[0] is nil */
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "(br_if $brk_%d (ref.is_null "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0))))\n",
                label);
            /* update k to results[0] */
            emit_indent(c, depth + 2);
            wat_appendf(c->w,
                "(local.set %s "
                "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0)))\n", f_k);
            /* Bind loop vars from results. A captured var gets a FRESH $Box
             * each iteration so closures over it see distinct values
             * (Lua 5.4+ semantics), rather than sharing one mutated cell. */
            for (int i = 0; i < s->as.for_gen.n_names; i++) {
                int li = s->as.for_gen.local_idxs[i];
                emit_indent(c, depth + 2);
                if (slot_is_boxed(c, li)) {
                    wat_appendf(c->w,
                        "(local.set $L%d (struct.new $Box "
                        "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                        "(i32.const %d))))\n", li, i);
                } else {
                    wat_appendf(c->w,
                        "(local.set $L%d "
                        "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                        "(i32.const %d)))\n", li, i);
                }
            }
            /* body */
            c->for_depth++;
            emit_block(c, &s->as.for_gen.body, depth + 2);
            c->for_depth--;
            emit_indent(c, depth + 2); wat_appendf(c->w, "br $cont_%d\n", label);
            emit_indent(c, depth + 1); wat_append(c->w, ")\n");
            emit_indent(c, depth);     wat_append(c->w, ")\n");
            c->break_depth--;
            break;
        }

        case STMT_GLOBAL: {
            int n_names = s->as.global_decl.n_names;
            int n_values = s->as.global_decl.n_values;
            if (n_values == 0) break;
            int last_call = (n_values > 0 &&
                             is_multival_tail(s->as.global_decl.values[n_values - 1]));
            if (last_call) {
                emit_indent(c, depth); wat_append(c->w, "(local.set $tmp_args\n");
                emit_multival_array(c, s->as.global_decl.values[n_values - 1], depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            for (int i = 0; i < n_names; i++) {
                int gi = s->as.global_decl.global_idxs[i];
                const char *gname = c->pr->globals.items[gi].name;
                size_t gnl = c->pr->globals.items[gi].name_len;
                emit_indent(c, depth);
                wat_append(c->w, "(call $tab_set (ref.as_non_null (global.get $g_globals))\n");
                emit_indent(c, depth + 1);
                emit_global_key(c, gname, gnl);
                if (n_values == 0) {
                    emit_indent(c, depth + 1); wat_append(c->w, "(ref.null any)\n");
                } else {
                    emit_distributed_value(c, i, n_values, s->as.global_decl.values,
                                           last_call, depth + 1);
                }
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            break;
        }

        case STMT_IF: {
            int label = c->next_label++;
            emit_indent(c, depth);
            wat_appendf(c->w, "(block $if_end_%d\n", label);
            for (size_t i = 0; i < s->as.if_stmt.narms; i++) {
                IfArm *a = &s->as.if_stmt.arms[i];
                emit_expr(c, a->cond, depth + 1);
                emit_indent(c, depth + 1); wat_append(c->w, "(call $lua_truthy)\n");
                emit_indent(c, depth + 1); wat_append(c->w, "(if (then\n");
                emit_block(c, &a->body, depth + 2);
                emit_indent(c, depth + 2); wat_appendf(c->w, "br $if_end_%d\n", label);
                emit_indent(c, depth + 1); wat_append(c->w, "))\n");
            }
            if (s->as.if_stmt.has_else) {
                emit_block(c, &s->as.if_stmt.else_body, depth + 1);
            }
            emit_indent(c, depth); wat_append(c->w, ")\n");
            break;
        }

        case STMT_LOCAL_FUNC: {
            int slot = s->as.local_func.local_idx;
            int boxed = slot_is_boxed(c, slot);
            /* If the slot is captured (e.g. by the closure itself for
             * recursion), pre-allocate the box with nil so the function body
             * can see its own slot; then store the closure into the box.
             * If not captured, simply build the closure and store it. */
            if (boxed) {
                emit_indent(c, depth);
                wat_appendf(c->w,
                    "(local.set $L%d (struct.new $Box (ref.null any)))\n", slot);
                emit_indent(c, depth); wat_append(c->w, "(struct.set $Box $v\n");
                emit_indent(c, depth + 1);
                wat_appendf(c->w, "(local.get $L%d)\n", slot);
                emit_function_expr(c, s->as.local_func.func, depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            } else {
                emit_indent(c, depth);
                wat_appendf(c->w, "(local.set $L%d\n", slot);
                emit_function_expr(c, s->as.local_func.func, depth + 1);
                emit_indent(c, depth); wat_append(c->w, ")\n");
            }
            break;
        }
    }
}

/* Collect <close> local slots declared at this block level (not in
 * nested blocks). Slots are returned in declaration order — caller
 * closes them in REVERSE order at scope exit. Returns count.
 * Caps at 32 close locals per block; that's more than realistic. */
static int collect_close_slots(const Block *b, int *out_slots, int cap) {
    int n = 0;
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *s = b->items[i];
        if (s->kind != STMT_LOCAL) continue;
        if (!s->as.local.attribs) continue;
        for (int j = 0; j < s->as.local.n_names; j++) {
            if (s->as.local.attribs[j] == 2 && n < cap) {
                out_slots[n++] = s->as.local.local_idxs[j];
            }
        }
    }
    return n;
}

/* Emit close calls in REVERSE declaration order. Milestone-23 minimal:
 * called only on natural block exit. Return/break/error in the block
 * skip the close — a documented limitation. */
static void emit_close_calls(CG *c, const int *slots, int n, int depth) {
    for (int i = n - 1; i >= 0; i--) {
        int slot = slots[i];
        emit_indent(c, depth);
        if (slot_is_boxed(c, slot)) {
            wat_appendf(c->w,
                "(call $do_close (struct.get $Box $v (local.get $L%d)) "
                "(ref.null any))\n", slot);
        } else {
            wat_appendf(c->w,
                "(call $do_close (local.get $L%d) (ref.null any))\n", slot);
        }
    }
}

/* Emit a goto-able block as a dispatch table:
 *
 *   (block $exit_BID
 *     (loop  $dispatch_BID
 *       (block $seg_BID_N
 *         …
 *         (block $seg_BID_1
 *           (block $seg_BID_0
 *             (br_table $seg_BID_0 $seg_BID_1 … $seg_BID_N $exit_BID
 *                       (local.get $next_BID))
 *           )
 *           <segment 0 body>
 *           (local.set $next_BID 1) (br $dispatch_BID)
 *         )
 *         <segment 1 body>
 *         (local.set $next_BID 2) (br $dispatch_BID)
 *       )
 *       …
 *       <segment N body>
 *       (br $exit_BID)
 *     )
 *   )
 *
 * Where BID is the block's dispatch id (= id of the first label declared
 * in it). Segments are: segment 0 = the stmts before the first label;
 * segment k (1..N) = the stmts at label k (after the label itself). A
 * goto to a label in this block becomes
 *     (local.set $next_BID K) (br $dispatch_BID)
 * — and the same shape works for jumps OUT of nested blocks because the
 * $next_BID local is function-scoped and $dispatch_BID is just a label
 * br can traverse through.
 *
 * This handles every label graph including interleaved forward+backward
 * scopes (the original cross-label-overlap case the old nested-blocks
 * lowering had to bail out on). */
static void emit_block(CG *c, const Block *b, int depth) {
    /* Fast path: no labels in this block, no wrappers needed. */
    int has_labels = 0;
    for (size_t i = 0; i < b->count; i++) {
        if (b->items[i]->kind == STMT_LABEL) { has_labels = 1; break; }
    }
    int close_slots[32];
    int n_close = collect_close_slots(b, close_slots, 32);
    if (!has_labels) {
        for (size_t i = 0; i < b->count; i++) emit_stmt(c, b->items[i], depth);
        emit_close_calls(c, close_slots, n_close, depth);
        return;
    }

    /* Compute segment boundaries: seg_start[k] = index of the first stmt
     * in segment k (k = 0..N). Segment 0 starts at 0; segment k>=1 starts
     * at the position AFTER the k-th label statement. */
    int seg_start[65];                          /* up to 64 labels + sentinel */
    int N = 0;
    int bid = -1;
    seg_start[0] = 0;
    for (size_t i = 0; i < b->count; i++) {
        Stmt *st = b->items[i];
        if (st->kind != STMT_LABEL) continue;
        if (N == 0) bid = st->as.label.block_dispatch_id;
        N++;
        if (N >= 64) { cg_error(c, "too many labels in one block (limit 64)"); return; }
        seg_start[N] = (int)i + 1;
    }
    int seg_end_N = (int)b->count;              /* end of segment N */

    /* Reset the dispatch state on entry: $next_BID is a function-scoped
     * local, so a previous entry (e.g. a previous iteration of an
     * enclosing for-loop) would otherwise leave us pointing at the wrong
     * segment. */
    emit_indent(c, depth);
    wat_appendf(c->w, "(local.set $next_%d (i32.const 0))\n", bid);
    /* Outer (block $exit_BID) — natural fall-through and gotos exit here. */
    emit_indent(c, depth);
    wat_appendf(c->w, "(block $exit_%d\n", bid);
    /* Dispatch loop — backward jumps go through here. */
    emit_indent(c, depth + 1);
    wat_appendf(c->w, "(loop $dispatch_%d\n", bid);

    /* Open N+1 nested (block $seg_BID_k …) from outermost (k=N) to innermost (k=0). */
    for (int k = N; k >= 0; k--) {
        emit_indent(c, depth + 2 + (N - k));
        wat_appendf(c->w, "(block $seg_%d_%d\n", bid, k);
    }
    /* Innermost: the br_table. Targets in order: seg_0, seg_1, …, seg_N, exit. */
    emit_indent(c, depth + 3 + N);
    wat_append(c->w, "(br_table");
    for (int k = 0; k <= N; k++) wat_appendf(c->w, " $seg_%d_%d", bid, k);
    wat_appendf(c->w, " $exit_%d (local.get $next_%d))\n", bid, bid);
    /* Close the innermost block ($seg_BID_0). */
    emit_indent(c, depth + 2 + N);
    wat_append(c->w, ")\n");

    /* Emit segment 0..N bodies. After each segment's closing paren of its
     * own (block) wrapper, we are at depth = depth + 2 + (N-k) — i.e. for
     * segment k we sit "between" the close of $seg_BID_k and the close of
     * $seg_BID_{k+1}. */
    for (int k = 0; k <= N; k++) {
        int body_depth = depth + 2 + (N - k);
        int start = seg_start[k];
        int end = (k < N) ? seg_start[k + 1] - 1 /* skip the label stmt */
                          : seg_end_N;
        for (int i = start; i < end; i++) {
            Stmt *st = b->items[i];
            if (st->kind == STMT_LABEL) continue; /* labels are markers, not code */
            emit_stmt(c, st, body_depth);
        }
        if (k < N) {
            /* Fall through to segment k+1 by re-entering the dispatch. */
            emit_indent(c, body_depth);
            wat_appendf(c->w, "(local.set $next_%d (i32.const %d))\n", bid, k + 1);
            emit_indent(c, body_depth);
            wat_appendf(c->w, "(br $dispatch_%d)\n", bid);
            /* Close the surrounding $seg_BID_{k+1} block now that this
             * segment's body is complete. */
            emit_indent(c, body_depth - 1);
            wat_append(c->w, ")\n");
        } else {
            /* Last segment: natural exit from the dispatched block. */
            emit_indent(c, body_depth);
            wat_appendf(c->w, "(br $exit_%d)\n", bid);
        }
    }
    /* Close the loop and outer block. */
    emit_indent(c, depth + 1);
    wat_append(c->w, ")\n");
    emit_indent(c, depth);
    wat_append(c->w, ")\n");
    emit_close_calls(c, close_slots, n_close, depth);
}

/* Walk a block body collecting dispatch ids of every block-with-labels.
 * Output is the set of distinct ids (no duplicates because each block's
 * dispatch id is uniquely the id of its first label). */
static void collect_dispatch_ids(const Block *b, int *out, int *n, int cap);
static void collect_dispatch_ids_stmt(const Stmt *s, int *out, int *n, int cap) {
    switch (s->kind) {
    case STMT_DO:      collect_dispatch_ids(&s->as.do_stmt.body,    out, n, cap); break;
    case STMT_WHILE:   collect_dispatch_ids(&s->as.while_stmt.body, out, n, cap); break;
    case STMT_REPEAT:  collect_dispatch_ids(&s->as.repeat.body,     out, n, cap); break;
    case STMT_FOR_NUM: collect_dispatch_ids(&s->as.for_num.body,    out, n, cap); break;
    case STMT_FOR_GEN: collect_dispatch_ids(&s->as.for_gen.body,    out, n, cap); break;
    case STMT_IF:
        for (size_t i = 0; i < s->as.if_stmt.narms; i++)
            collect_dispatch_ids(&s->as.if_stmt.arms[i].body, out, n, cap);
        if (s->as.if_stmt.has_else)
            collect_dispatch_ids(&s->as.if_stmt.else_body, out, n, cap);
        break;
    default: break;
    }
}
static void collect_dispatch_ids(const Block *b, int *out, int *n, int cap) {
    /* Find the first label in this block (if any) — its id is the dispatch id. */
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *st = b->items[i];
        if (st->kind == STMT_LABEL) {
            if (*n < cap) out[(*n)++] = st->as.label.block_dispatch_id;
            break;
        }
    }
    for (size_t i = 0; i < b->count; i++) {
        collect_dispatch_ids_stmt(b->items[i], out, n, cap);
    }
}

/* Deepest nesting of numeric/generic for-loops in a block. Each for-loop
 * adds one level; other compound statements pass their inner depth through
 * unchanged (only for-loops own $for_* scratch). The result sizes the
 * per-level scratch declarations in the function prologue. */
static int max_for_nesting(const Block *b) {
    int best = 0;
    if (!b) return 0;
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *s = b->items[i];
        int d = 0;
        switch (s->kind) {
        case STMT_FOR_NUM: d = 1 + max_for_nesting(&s->as.for_num.body); break;
        case STMT_FOR_GEN: d = 1 + max_for_nesting(&s->as.for_gen.body); break;
        case STMT_WHILE:   d = max_for_nesting(&s->as.while_stmt.body); break;
        case STMT_REPEAT:  d = max_for_nesting(&s->as.repeat.body); break;
        case STMT_DO:      d = max_for_nesting(&s->as.do_stmt.body); break;
        case STMT_IF:
            for (size_t a = 0; a < s->as.if_stmt.narms; a++) {
                int da = max_for_nesting(&s->as.if_stmt.arms[a].body);
                if (da > d) d = da;
            }
            if (s->as.if_stmt.has_else) {
                int de = max_for_nesting(&s->as.if_stmt.else_body);
                if (de > d) d = de;
            }
            break;
        default: break;
        }
        if (d > best) best = d;
    }
    return best;
}

/* Emit the per-level $for_* scratch locals for a function body. */
static void emit_for_scratch_locals(WatBuilder *w, const Block *body) {
    int levels = max_for_nesting(body);
    for (int d = 0; d < levels; d++) {
        wat_appendf(w,
            "    (local $for_stop_%d anyref) (local $for_step_%d anyref)"
            " (local $for_next_%d anyref) (local $for_cur_%d anyref)\n", d, d, d, d);
        wat_appendf(w,
            "    (local $for_iter_%d anyref) (local $for_state_%d anyref)"
            " (local $for_k_%d anyref)\n", d, d, d);
    }
}

/* ============================================================
 * Static prelude
 * ============================================================ */

static const char PRELUDE[] = {
#embed "prelude.wat"
, '\0'
};

/* The first LITERAL_PREFIX_LEN bytes of $str_data are reserved error
 * messages and field names that prelude.wat addresses by *absolute* offset
 * (e.g. `$throw_lit (i32.const 430) (i32.const 25)`). The byte map lives in
 * LITERAL_SLAB below; verify_literal_slab() checks that LITERAL_PREFIX and
 * that map agree, so an edit to one without the other fails the build
 * instead of silently corrupting messages or reading past the slab. */
#define LITERAL_PREFIX "niltruefalse<float>numberstringtablefunctionboolean__index__add__eq\tLua 5.5'for' step is zeroattempt to call a non-function value__callmodule '' not loadedvalue out of rangedata does not fitinvalid UTF-8 codeattempt to perform arithmeticattempt to index a valuetable index is niltable index is NaNtoo largeyearmonthdayhourminsecwdayydayisdsttable overflowout of limitsmissing sizevariable-length formatnot power of 2invalid formatattempt to divide by zeroattempt to perform 'n%0'attempt to compare two values'__tostring' must return a string'__newindex' chain too long; possible loopattempt to close a non-closable valuevalue expectedcannot change a protected metatablestring expectedtable expectedtable or string expectedinvalid replacement valuestring contains zeros<no error object>invalid value in table for 'concat'base out of rangeposition out of boundsinitial position is a continuation bytefield missing in date tablewrong number of argumentsnumber expected, got stack overflownumber has no integer representation"
#define LITERAL_PREFIX_LEN 1021
static_assert(sizeof(LITERAL_PREFIX) - 1 == LITERAL_PREFIX_LEN,
              "LITERAL_PREFIX_LEN must match the byte length of LITERAL_PREFIX");

/* Executable form of the slab map. Each row is the absolute offset baked
 * into prelude.wat and the bytes that must live there. Offsets are
 * contiguous (each = previous offset + previous length); the trailing
 * comment names the prelude consumer. */
static const struct { unsigned off; const char *s; } LITERAL_SLAB[] = {
    {  0, "nil"        }, {  3, "true"    }, {  7, "false"   }, { 12, "<float>"  },
    { 19, "number"     }, { 25, "string"  }, { 31, "table"   }, { 36, "function" },
    { 44, "boolean"    }, { 51, "__index" }, { 58, "__add"   }, { 63, "__eq"     },
    { 67, "\t"         }, { 68, "Lua 5.5" },
    { 75, "'for' step is zero" },                 /* $for_check_step */
    { 93, "attempt to call a non-function value" },/* $lua_call_any */
    {129, "__call"     },                          /* $g_mkey_call */
    {135, "module '"   }, {143, "' not loaded" },  /* $builtin_require */
    {155, "value out of range" },                  /* $builtin_string_char, … */
    {173, "data does not fit" },                   /* $builtin_string_unpack */
    {190, "invalid UTF-8 code" },                  /* $builtin_utf8_codepoint, … */
    {208, "attempt to perform arithmetic" },       /* $arith_mm */
    {237, "attempt to index a value" },            /* $lua_tabset, $lua_index */
    {261, "table index is nil" },                  /* $builtin_rawset, $tab_set */
    {279, "table index is NaN" },                  /* $builtin_rawset, $tab_set */
    {297, "too large"  },                          /* $builtin_string_rep */
    {306, "year" }, {310, "month"}, {315, "day"  }, {318, "hour" }, /* os.date("*t") */
    {322, "min"  }, {325, "sec"  }, {328, "wday" }, {332, "yday" }, {336, "isdst"},
    {341, "table overflow" },                      /* $tab_grow size guard */
    {355, "out of limits" },                       /* pack size/align validation */
    {368, "missing size" },                        /* pack 'c' missing [N] */
    {380, "variable-length format" },              /* packsize on 's'/'z' */
    {402, "not power of 2" },                       /* pack '!N' validation */
    {416, "invalid format" },                       /* packsize 'c' overflow */
    {430, "attempt to divide by zero" },           /* $lua_fdiv divisor 0 */
    {455, "attempt to perform 'n%0'" },            /* $lua_mod divisor 0 */
    {479, "attempt to compare two values" },       /* $compare_mm */
    {508, "'__tostring' must return a string" },   /* $lua_tostring */
    {541, "'__newindex' chain too long; possible loop" }, /* $lua_tabset */
    {583, "attempt to close a non-closable value" },/* $do_close */
    {620, "value expected" },                      /* pcall/xpcall/select */
    {634, "cannot change a protected metatable" }, /* $builtin_setmetatable */
    {669, "string expected" },                     /* require/os.getenv */
    {684, "table expected" },                      /* $builtin_rawget */
    {698, "table or string expected" },            /* $builtin_rawlen */
    {722, "invalid replacement value" },           /* gsub replacement paths */
    {747, "string contains zeros" },               /* $builtin_string_pack 'z' */
    {768, "<no error object>" },                    /* $err_or_noobj */
    {785, "invalid value in table for 'concat'" },  /* $builtin_table_concat */
    {820, "base out of range" },                    /* $builtin_tonumber */
    {837, "position out of bounds" },               /* $builtin_utf8_offset */
    {859, "initial position is a continuation byte" }, /* $builtin_utf8_offset */
    {898, "field missing in date table" },          /* $os_date_field */
    {925, "wrong number of arguments" },            /* $builtin_table_insert */
    {950, "number expected, got " },                /* $as_float_co / $as_int_co */
    {971, "stack overflow" },                       /* $push_call_frame depth guard */
    {985, "number has no integer representation" },  /* $as_int_co */
};

/* Returns the offending entry's string on drift between LITERAL_PREFIX and
 * LITERAL_SLAB (gap/overlap, content mismatch, or total != prefix length),
 * or NULL when the slab is internally consistent. */
static const char *verify_literal_slab(void) {
    unsigned expect_off = 0;
    for (size_t i = 0; i < sizeof(LITERAL_SLAB) / sizeof(LITERAL_SLAB[0]); i++) {
        unsigned off = LITERAL_SLAB[i].off;
        size_t len = strlen(LITERAL_SLAB[i].s);
        if (off != expect_off) return LITERAL_SLAB[i].s;
        if (off + len > LITERAL_PREFIX_LEN) return LITERAL_SLAB[i].s;
        if (memcmp(&LITERAL_PREFIX[off], LITERAL_SLAB[i].s, len) != 0)
            return LITERAL_SLAB[i].s;
        expect_off = off + (unsigned)len;
    }
    return expect_off == LITERAL_PREFIX_LEN ? NULL : "(slab total length)";
}

/* WAT type keyword for an inferred numeric type. */
static const char *num_wat_ty(NumTy t) {
    return t == NT_INT ? "i64" : t == NT_FLOAT ? "f64" : "anyref";
}

/* Emit the body of one user function. */
static void emit_user_function(CG *c, const LuaFunc *fn, int direct, int ret_single) {
    WatBuilder *w = c->w;
    const FuncSig *sg = (c->opt_int && fn->func_idx >= 0 && fn->func_idx < c->n_sigs)
                            ? &c->sigs[fn->func_idx] : NULL;
    /* Typed direct entries seed their parameter slots from the signature; the
     * generic entry and the main chunk leave parameters boxed. */
    const NumTy *param_seed = (direct && sg) ? sg->param_ty : NULL;
    NumTy ret_ty = (direct && ret_single && sg) ? sg->ret_ty : NT_ANY;
    if (direct) {
        /* Direct-args entry: closure + one (typed) param per declared parameter,
         * no $args/$ArgArr. ret_single ($user_N_da1) returns a single value of
         * the inferred result type; otherwise ($user_N_da) the array-based
         * return. Same body as $user_N either way. */
        wat_appendf(w, "  (func $user_%d_%s (param $closure (ref $LuaClosure))",
                    fn->func_idx, ret_single ? "da1" : "da");
        for (int i = 0; i < fn->n_params; i++)
            wat_appendf(w, " (param $p%d %s)", i,
                        num_wat_ty(param_seed ? param_seed[i] : NT_ANY));
        if (ret_single) wat_appendf(w, " (result %s)\n", num_wat_ty(ret_ty));
        else            wat_append(w, " (result (ref $ArgArr))\n");
    } else {
        wat_appendf(w,
            "  (func $user_%d (type $LuaFn) "
            "(param $closure (ref $LuaClosure)) "
            "(param $args (ref $ArgArr)) (result (ref $ArgArr))\n",
            fn->func_idx);
    }

    /* Wire escape-analysis state for this body. */
    const unsigned char *prev_captured = c->cur_captured;
    int prev_n_locals = c->cur_n_locals;
    const unsigned char *prev_is_int = c->cur_is_int;
    const unsigned char *prev_is_float = c->cur_is_float;
    const LuaFunc **prev_func_slot = c->cur_func_slot, **prev_upval = c->cur_upval_func;
    int prev_n_params = c->cur_n_params, prev_func_idx = c->cur_func_idx;
    c->cur_captured = fn->captured;
    c->cur_n_locals = fn->n_locals;
    c->cur_n_params = fn->n_params;
    /* Direct-call resolution uses the global binding maps for this function. */
    c->cur_func_idx = fn->func_idx;
    c->cur_func_slot = c->bind_slot ? c->bind_slot[fn->func_idx] : NULL;
    c->cur_upval_func = c->bind_upval ? c->bind_upval[fn->func_idx] : NULL;
    unsigned char *isint = NULL, *isfloat = NULL;
    if (c->opt_int) {
        /* The int/float slot analysis recognizes direct calls (expr_is_int on
         * EXPR_CALL needs cur_func_slot/cur_upval_func, set just above), so a
         * slot assigned the result of an int-returning call is itself typed int. */
        isint = calloc(fn->n_locals ? fn->n_locals : 1, 1);
        compute_int_slots(c, &fn->body, fn->n_locals, fn->n_params, fn->captured, isint, param_seed);
        c->cur_is_int = isint;
        isfloat = calloc(fn->n_locals ? fn->n_locals : 1, 1);
        compute_float_slots(c, &fn->body, fn->n_locals, fn->n_params, fn->captured, isfloat, param_seed);
    }
    c->cur_is_int = isint;
    c->cur_is_float = isfloat;

    /* Run the label pre-pass NOW so block_dispatch_id is populated on
     * every label and goto before we emit the $next_BID i32 locals. */
    int saved_next_id_pre = c->next_label_id;
    c->next_label_id = 0;
    la_block(c, &fn->body, NULL);

    for (int i = 0; i < fn->n_locals; i++) {
        if (isint && isint[i]) {
            wat_appendf(w, "    (local $L%d i64)\n", i);
        } else if (isfloat && isfloat[i]) {
            wat_appendf(w, "    (local $L%d f64)\n", i);
        } else if (fn->captured && fn->captured[i]) {
            wat_appendf(w, "    (local $L%d (ref $Box))\n", i);
        } else {
            wat_appendf(w, "    (local $L%d anyref)\n", i);
        }
    }
    wat_append(w, "    (local $tmp_any anyref)\n");
    wat_append(w, "    (local $tmp_args (ref null $ArgArr))\n");
    wat_append(w, "    (local $tmp_clo (ref null $LuaClosure))\n");
    wat_append(w, "    (local $tmp_callee anyref)\n");
    wat_append(w, "    (local $tmp_tab (ref null $LuaTable))\n");
    wat_append(w, "    (local $tmp_lhs_t (ref null $ArgArr))\n");
    wat_append(w, "    (local $tmp_lhs_k (ref null $ArgArr))\n");
    emit_for_scratch_locals(w, &fn->body);
    if (c->opt_int) {
        int lv = max_for_nesting(&fn->body);
        for (int d = 0; d < lv; d++)
            wat_appendf(w, "    (local $ifor_stop_%d i64) (local $ifor_step_%d i64)"
                           " (local $ifor_next_%d i64)\n", d, d, d);
    }
    if (fn->is_vararg) {
        /* Non-null: prologue always writes $varargs before first use. */
        wat_append(w, "    (local $varargs (ref $ArgArr))\n");
    }
    /* Pre-pass found these; emit one i32 local per dispatch block in this
     * function so STMT_GOTO can target them and emit_block can read them
     * in br_table. Default-zero i32 ⇒ first dispatch lands in segment 0. */
    {
        int bids[128]; int n = 0;
        collect_dispatch_ids(&fn->body, bids, &n, 128);
        for (int i = 0; i < n; i++) {
            wat_appendf(w, "    (local $next_%d i32)\n", bids[i]);
        }
    }

    /* Param extraction: from args[i] (normal) or the direct $pi param. */
    for (int i = 0; i < fn->n_params; i++) {
        char src[64];
        if (direct) snprintf(src, sizeof src, "(local.get $p%d)", i);
        else        snprintf(src, sizeof src, "(call $args_at (local.get $args) (i32.const %d))", i);
        if (fn->captured && fn->captured[i])
            wat_appendf(w, "    (local.set $L%d (struct.new $Box %s))\n", i, src);
        else
            wat_appendf(w, "    (local.set $L%d %s)\n", i, src);
    }
    if (fn->is_vararg) {
        wat_appendf(w,
            "    (local.set $varargs (call $args_slice "
            "(local.get $args) (i32.const %d)))\n", fn->n_params);
    }
    /* Eager-initialise every captured local that isn't a parameter to a
     * placeholder $Box. Lua semantics guarantees a local's declaration
     * runs before any reference, but with dispatch-table goto lowering
     * the wasm validator can't always prove that statically. A placeholder
     * keeps the slot non-null; the real `local x = …` statement replaces
     * the box, and any closure captured at that point holds the fresh
     * one — no observable difference from the old eager-only-on-decl scheme. */
    for (int i = fn->n_params; i < fn->n_locals; i++) {
        if (fn->captured && fn->captured[i]) {
            wat_appendf(w,
                "    (local.set $L%d (struct.new $Box (ref.null any)))\n", i);
        }
    }

    int was_in_main = c->in_main;
    int prev_ret_single = c->ret_single;
    NumTy prev_ret_ty = c->cur_ret_ty;
    c->in_main = 0;
    c->ret_single = ret_single;
    c->cur_ret_ty = ret_ty;
    if (c->ok) emit_block(c, &fn->body, 2);
    c->next_label_id = saved_next_id_pre;
    c->in_main = was_in_main;
    c->ret_single = prev_ret_single;
    c->cur_ret_ty = prev_ret_ty;

    /* Default trailing fall-through value. A numeric ret_ty implies the body
     * always returns (block_always_returns), so this default is dead but must
     * still type-check; otherwise it is nil / the empty results array. */
    if (ret_single)
        wat_appendf(w, "    %s\n", ret_ty == NT_INT ? "(i64.const 0)"
                                 : ret_ty == NT_FLOAT ? "(f64.const 0)"
                                 : "(ref.null any)");
    else
        wat_append(w, "    (global.get $g_empty_args)\n");
    wat_append(w, "  )\n");

    /* Declare so the funcref is usable in const init / closures. The direct
     * entry is only ever called by name, so it needs no elem declare. */
    if (!direct)
        wat_appendf(w, "  (elem declare func $user_%d)\n", fn->func_idx);

    c->cur_captured = prev_captured;
    c->cur_n_locals = prev_n_locals;
    c->cur_is_int = prev_is_int;
    c->cur_is_float = prev_is_float;
    c->cur_func_slot = prev_func_slot;
    c->cur_upval_func = prev_upval;
    c->cur_func_idx = prev_func_idx;
    c->cur_n_params = prev_n_params;
    free(isint);
    free(isfloat);
}

/* ---------- tree-shaking (milestone 0 / size opt) ---------- */
/* mark_* walks the AST and records which top-level builtins and which
 * pre-declared globals are referenced. Used by codegen_module to skip
 * emitting closure globals, _G entries, and library installations
 * that nothing in the program touches. */
typedef struct {
    unsigned char *live;      /* builtin idx -> 1 if referenced */
    unsigned char *gref;      /* pr->globals idx -> 1 if referenced */
    int n_builtins;
    int n_globals;
} LiveSet;

static void ts_mark_expr(LiveSet *L, const Expr *e);
static void ts_mark_stmt(LiveSet *L, const Stmt *s);
static void ts_mark_block(LiveSet *L, const Block *b) {
    if (!b) return;
    for (size_t i = 0; i < b->count; i++) ts_mark_stmt(L, b->items[i]);
}

static void ts_mark_var(LiveSet *L, VarKind k, int idx) {
    if (k == VAR_BUILTIN && idx >= 0 && idx < L->n_builtins) L->live[idx] = 1;
    else if (k == VAR_GLOBAL && idx >= 0 && idx < L->n_globals) L->gref[idx] = 1;
}

static void ts_mark_expr(LiveSet *L, const Expr *e) {
    if (!e) return;
    switch (e->kind) {
        case EXPR_VAR: ts_mark_var(L, e->as.var.kind, e->as.var.idx); break;
        case EXPR_CALL:
            ts_mark_expr(L, e->as.call.callee);
            for (size_t i = 0; i < e->as.call.nargs; i++)
                ts_mark_expr(L, e->as.call.args[i]);
            break;
        case EXPR_BINOP:
            ts_mark_expr(L, e->as.binop.lhs);
            ts_mark_expr(L, e->as.binop.rhs);
            break;
        case EXPR_UNOP: ts_mark_expr(L, e->as.unop.operand); break;
        case EXPR_FUNCTION:
            ts_mark_block(L, &e->as.func_expr.func->body);
            break;
        case EXPR_INDEX:
            ts_mark_expr(L, e->as.index.table);
            ts_mark_expr(L, e->as.index.key);
            break;
        case EXPR_TABLE:
            for (int i = 0; i < e->as.table_ctor.n_entries; i++) {
                ts_mark_expr(L, e->as.table_ctor.entries[i].key);
                ts_mark_expr(L, e->as.table_ctor.entries[i].value);
            }
            break;
        case EXPR_METHOD_CALL:
            ts_mark_expr(L, e->as.method_call.recv);
            for (size_t i = 0; i < e->as.method_call.nargs; i++)
                ts_mark_expr(L, e->as.method_call.args[i]);
            break;
        default: break;  /* literals, vararg — no refs */
    }
}

static void ts_mark_stmt(LiveSet *L, const Stmt *s) {
    if (!s) return;
    switch (s->kind) {
        case STMT_LOCAL:
            for (int i = 0; i < s->as.local.n_values; i++)
                ts_mark_expr(L, s->as.local.values[i]);
            break;
        case STMT_ASSIGN:
            for (int i = 0; i < s->as.assign.n_targets; i++) {
                const AssignTarget *t = &s->as.assign.targets[i];
                if (t->kind == TGT_INDEX) {
                    ts_mark_expr(L, t->as.index.table);
                    ts_mark_expr(L, t->as.index.key);
                } else {
                    ts_mark_var(L, t->as.var.kind, t->as.var.idx);
                }
            }
            for (int i = 0; i < s->as.assign.n_values; i++)
                ts_mark_expr(L, s->as.assign.values[i]);
            break;
        case STMT_EXPR: ts_mark_expr(L, s->as.expr_stmt.expr); break;
        case STMT_IF:
            for (size_t i = 0; i < s->as.if_stmt.narms; i++) {
                ts_mark_expr(L, s->as.if_stmt.arms[i].cond);
                ts_mark_block(L, &s->as.if_stmt.arms[i].body);
            }
            if (s->as.if_stmt.has_else)
                ts_mark_block(L, &s->as.if_stmt.else_body);
            break;
        case STMT_WHILE:
            ts_mark_expr(L, s->as.while_stmt.cond);
            ts_mark_block(L, &s->as.while_stmt.body);
            break;
        case STMT_DO: ts_mark_block(L, &s->as.do_stmt.body); break;
        case STMT_RETURN:
            for (int i = 0; i < s->as.return_stmt.n_values; i++)
                ts_mark_expr(L, s->as.return_stmt.values[i]);
            break;
        case STMT_LOCAL_FUNC:
            ts_mark_block(L, &s->as.local_func.func->body);
            break;
        case STMT_FOR_NUM:
            ts_mark_expr(L, s->as.for_num.start);
            ts_mark_expr(L, s->as.for_num.stop);
            ts_mark_expr(L, s->as.for_num.step);
            ts_mark_block(L, &s->as.for_num.body);
            break;
        case STMT_FOR_GEN:
            for (int i = 0; i < s->as.for_gen.n_exprs; i++)
                ts_mark_expr(L, s->as.for_gen.exprs[i]);
            ts_mark_block(L, &s->as.for_gen.body);
            break;
        case STMT_REPEAT:
            ts_mark_block(L, &s->as.repeat.body);
            ts_mark_expr(L, s->as.repeat.cond);
            break;
        case STMT_GLOBAL:
            for (int i = 0; i < s->as.global_decl.n_values; i++)
                ts_mark_expr(L, s->as.global_decl.values[i]);
            break;
        default: break;  /* BREAK, GOTO, LABEL — no refs */
    }
}

/* Map a global name to a BuiltinClass if it's one of the pre-declared
 * library tables. Returns -1 otherwise. */
static int class_for_global(const char *name, size_t name_len) {
    if (name_len == 4 && memcmp(name, "math", 4) == 0)   return BLT_LIB_MATH;
    if (name_len == 6 && memcmp(name, "string", 6) == 0) return BLT_LIB_STRING;
    if (name_len == 2 && memcmp(name, "io", 2) == 0)     return BLT_LIB_IO;
    if (name_len == 5 && memcmp(name, "table", 5) == 0)  return BLT_LIB_TABLE;
    if (name_len == 4 && memcmp(name, "utf8", 4) == 0)   return BLT_LIB_UTF8;
    if (name_len == 5 && memcmp(name, "debug", 5) == 0)  return BLT_LIB_DEBUG;
    if (name_len == 2 && memcmp(name, "os", 2) == 0)     return BLT_LIB_OS;
    return -1;
}

static void compute_live_set(const ParseResult *pr, int n_builtins,
                             unsigned char *live, unsigned char *gref) {
    LiveSet L = { live, gref, n_builtins, (int)pr->globals.count };
    ts_mark_block(&L, &pr->main_body);
    for (size_t i = 0; i < pr->funcs.count; i++)
        ts_mark_block(&L, &pr->funcs.items[i]->body);

    /* If a library global was referenced, mark every member of that
     * class live (the whole table gets installed). */
    for (size_t gi = 0; gi < pr->globals.count; gi++) {
        if (!gref[gi]) continue;
        int cls = class_for_global(pr->globals.items[gi].name,
                                   pr->globals.items[gi].name_len);
        if (cls < 0) continue;
        for (int bi = 0; bi < n_builtins; bi++) {
            if ((int)builtin_class(bi) == cls) live[bi] = 1;
        }
    }

    /* Internal cross-references baked into the prelude. The bodies of
     * pairs/ipairs/utf8.codes read \$g_builtin_next /
     * \$g_builtin_ipairs_iter / \$g_builtin_utf8_codes_iter as singleton
     * iterator closures so callers get identity-stable iterators. Those
     * globals only exist when their builtin is live, and the prelude
     * body is always present in the binary (we don't drop unused
     * prelude funcs), so wasm-as would reject an unresolved global.
     *
     * Force these three "iterator" builtins live unconditionally so the
     * singleton globals + their elem declares are always emitted,
     * independent of whether the user actually calls pairs/ipairs/codes.
     * The size cost is one closure each. */
    for (int i = 0; i < n_builtins; i++) {
        const char *n = builtin_name(i);
        BuiltinClass c = builtin_class(i);
        if (c == BLT_TOPLEVEL &&
            (strcmp(n, "next") == 0 ||
             strcmp(n, "_ipairs_iter") == 0 ||
             strcmp(n, "_utf8_codes_iter") == 0)) {
            live[i] = 1;
        }
        /* The io.open / io.lines / file:lines bodies are part of the
         * always-present prelude and reference the file-handle method
         * closure globals + the lines iterator directly (via $g_*). Those
         * globals only exist when their builtin is live, so force these
         * live unconditionally — exactly like the iterator builtins above.
         * Cost is a handful of closures even when the program never opens
         * a file; the prelude bodies referencing them are unconditional. */
        if (c == BLT_LIB_IO &&
            (strcmp(n, "_file_read")  == 0 || strcmp(n, "_file_write") == 0 ||
             strcmp(n, "_file_close") == 0 || strcmp(n, "_file_flush") == 0 ||
             strcmp(n, "_file_seek")  == 0 || strcmp(n, "_file_lines") == 0 ||
             strcmp(n, "_io_lines_iter") == 0)) {
            live[i] = 1;
        }
    }
}

/* Build each referenced stdlib library table (math/string/io/table/utf8/
 * debug/os/package/coroutine) plus _VERSION, and install them in $g_globals.
 * Tree-shake skips a library whose global name was never referenced. */
static void emit_library_tables(CG *c, const unsigned char *gref, int nb) {
    WatBuilder *out = c->w;
    const ParseResult *pr = c->pr;
    const char *G = "(ref.as_non_null (global.get $g_globals))";
    (void)nb;
    /* Library tables + the _VERSION constant. Each library table is built
     * locally, then installed as $g_globals.<name>. With tree-shake on,
     * a library is skipped unless its global name was actually
     * referenced in user code. */
    for (size_t gi = 0; gi < pr->globals.count; gi++) {
        const char *gname = pr->globals.items[gi].name;
        size_t glen = pr->globals.items[gi].name_len;
        if (glen == 8 && memcmp(gname, "_VERSION", 8) == 0) {
            if (!gref[gi]) continue;
            emit_tab_set_strval(c, G, "_VERSION", 8, "Lua 5.5", 7);
            continue;
        }
        if (glen == 2 && memcmp(gname, "_G", 2) == 0) continue;  /* installed above */
        if (!gref[gi]) continue;  /* tree-shake: library not referenced */
        BuiltinClass cls;
        if      (glen == 4 && memcmp(gname, "math",   4) == 0) cls = BLT_LIB_MATH;
        else if (glen == 6 && memcmp(gname, "string", 6) == 0) cls = BLT_LIB_STRING;
        else if (glen == 2 && memcmp(gname, "io",     2) == 0) cls = BLT_LIB_IO;
        else if (glen == 5 && memcmp(gname, "table",  5) == 0) cls = BLT_LIB_TABLE;
        else if (glen == 4 && memcmp(gname, "utf8",   4) == 0) cls = BLT_LIB_UTF8;
        else if (glen == 5 && memcmp(gname, "debug",  5) == 0) cls = BLT_LIB_DEBUG;
        else if (glen == 2 && memcmp(gname, "os",     2) == 0) cls = BLT_LIB_OS;
        else if (glen == 7 && memcmp(gname, "package", 7) == 0) {
            /* Milestone 25: package = { loaded = {}, preload = {} }.
             * No builtins live under this table; require() walks it.
             * We also stub package.path, package.cpath, package.config so
             * tests that probe `type(package.path) == "string"` pass. */
            wat_append(out, "    (local.set $tab (call $tab_new))\n");
            static const struct { const char *key; const char *val; } PKG_STR[] = {
                { "loaded",  NULL },     /* table — handled separately */
                { "preload", NULL },
                { "path",    "" },       /* empty: there's no filesystem here */
                { "cpath",   "" },
                { "config",  "/\n;\n?\n!\n-\n" }, /* the stock Lua default */
            };
            for (size_t pi = 0; pi < sizeof(PKG_STR)/sizeof(PKG_STR[0]); pi++) {
                size_t klen = strlen(PKG_STR[pi].key);
                if (PKG_STR[pi].val == NULL)
                    emit_tab_set_str(c, "(local.get $tab)", PKG_STR[pi].key, klen,
                                     "(call $tab_new)");
                else
                    emit_tab_set_strval(c, "(local.get $tab)", PKG_STR[pi].key, klen,
                                        PKG_STR[pi].val, strlen(PKG_STR[pi].val));
            }
            emit_tab_set_str(c, G, gname, glen, "(local.get $tab)");
            continue;
        }
        else if (glen == 9 && memcmp(gname, "coroutine", 9) == 0) {
            /* Empty stub library — no functions installed. Enough to
             * satisfy `require "coroutine" == coroutine` style identity
             * checks and to keep `type(coroutine) == "table"` happy;
             * any actual coroutine.* call still trips later. */
            wat_append(out, "    (local.set $tab (call $tab_new))\n");
            emit_tab_set_str(c, G, gname, glen, "(local.get $tab)");
            continue;
        }
        else continue;
        wat_append(out, "    (local.set $tab (call $tab_new))\n");
        for (int bi = 0; bi < nb; bi++) {
            if (builtin_class(bi) != cls) continue;
            const char *key = builtin_lib_key(bi);
            /* Leading-underscore names are internal helpers (e.g. the
             * io file-handle methods). They get live-marked + closure
             * globals like any other builtin, but we don't expose them
             * as table keys on the library — codegen installs them
             * elsewhere on the right host objects. */
            if (key[0] == '_') continue;
            size_t key_len = strlen(key);
            StrRef sr = strpool_add(&c->strs, key, key_len);
            emit_tab_set_global(out, "$tab", sr, builtin_func_name(bi) + 1);
        }
        /* Plain-value constants for the math library. */
        if (cls == BLT_LIB_MATH) {
            emit_tab_set_str(c, "(local.get $tab)", "pi", 2,
                "(struct.new $LuaFloat (f64.const 3.141592653589793))");
            emit_tab_set_str(c, "(local.get $tab)", "huge", 4,
                "(struct.new $LuaFloat (f64.const inf))");
            emit_tab_set_str(c, "(local.get $tab)", "maxinteger", 10,
                "(call $make_int (i64.const 9223372036854775807))");
            emit_tab_set_str(c, "(local.get $tab)", "mininteger", 10,
                "(call $make_int (i64.const -9223372036854775808))");
        }
        /* io.stdout / io.stderr / io.stdin: build a sub-table per
         * stream, populated with the relevant file-handle methods. The
         * methods themselves were registered as leading-underscore
         * entries in builtins.c so the standard install loop above
         * skipped them, but their closure globals
         * ($g_io_handle_{write,err_write,read,noop}) are live and
         * ready to use. */
        if (cls == BLT_LIB_IO) {
            /* `method_glob == NULL` selects the read method on stdin;
             * the rest take a writer matching the handle's stream. */
            static const struct {
                const char *handle;
                size_t      handle_len;
                const char *method_glob;
                int         fd;             /* host fd; io.type reads __fd */
                const char *default_global; /* capture as a default io file, or NULL */
            } HANDLES[] = {
                { "stdout", 6, "io_handle_write",     1, "$g_io_output" },
                { "stderr", 6, "io_handle_err_write", 2, NULL           },
                { "stdin",  5, NULL,                  0, "$g_io_input"  },
            };
            StrRef wkey = strpool_add(&c->strs, "write", 5);
            StrRef rkey = strpool_add(&c->strs, "read",  4);
            StrRef ckey = strpool_add(&c->strs, "close", 5);
            StrRef fkey = strpool_add(&c->strs, "flush", 5);
            for (size_t hi = 0; hi < sizeof(HANDLES)/sizeof(HANDLES[0]); hi++) {
                wat_append(out, "    (local.set $h (call $tab_new))\n");
                if (HANDLES[hi].method_glob)
                    emit_tab_set_global(out, "$h", wkey, HANDLES[hi].method_glob);
                else
                    emit_tab_set_global(out, "$h", rkey, "io_handle_read");
                emit_tab_set_global(out, "$h", ckey, "io_handle_noop");
                emit_tab_set_global(out, "$h", fkey, "io_handle_noop");
                /* __fd so io.type reports "file" for the standard streams. */
                char fdexpr[48];
                snprintf(fdexpr, sizeof fdexpr,
                         "(call $make_int (i64.const %d))", HANDLES[hi].fd);
                emit_tab_set_str(c, "(local.get $h)", "__fd", 4, fdexpr);
                emit_tab_set_str(c, "(local.get $tab)", HANDLES[hi].handle,
                                 HANDLES[hi].handle_len, "(local.get $h)");
                if (HANDLES[hi].default_global)
                    wat_appendf(out, "    (global.set %s (local.get $h))\n",
                                HANDLES[hi].default_global);
            }
        }
        /* utf8.charpattern: the Lua-pattern string that matches one
         * UTF-8 codepoint. Binary content; strpool_add and data-segment
         * escaping handle the non-printable bytes. */
        if (cls == BLT_LIB_UTF8) {
            static const char CHARPAT[] =
                "[\x00-\x7F\xC2-\xFD][\x80-\xBF]*";
            emit_tab_set_strval(c, "(local.get $tab)", "charpattern", 11,
                                CHARPAT, sizeof(CHARPAT) - 1);
        }
        emit_tab_set_str(c, G, gname, glen, "(local.get $tab)");
    }
}

/* Forward each installed library into package.loaded so `require "name"`
 * returns it. Only emitted when package itself was built. */
static void emit_require_bridge(CG *c, const unsigned char *gref) {
    WatBuilder *out = c->w;
    const ParseResult *pr = c->pr;
    /* Make each stdlib library visible through `require "<name>"` by
     * registering it in `package.loaded`. The library tables have just
     * been installed in _G above; here we walk _G again, look up
     * package.loaded once, and forward each library reference into it. */
    {
        static const char *LIB_NAMES[] = {
            "math", "string", "io", "table", "utf8", "debug", "package",
            "os", "coroutine",
        };
        int need_any = 0;
        for (size_t li = 0; li < sizeof(LIB_NAMES) / sizeof(LIB_NAMES[0]); li++) {
            size_t llen = strlen(LIB_NAMES[li]);
            for (size_t gi = 0; gi < pr->globals.count; gi++) {
                if (pr->globals.items[gi].name_len == llen &&
                    memcmp(pr->globals.items[gi].name, LIB_NAMES[li], llen) == 0 &&
                    gref[gi]) {
                    need_any = 1; break;
                }
            }
            if (need_any) break;
        }
        /* Only emit the bridge code when package itself was built —
         * otherwise the (ref.cast (ref $LuaTable) ...) would trap. */
        int have_package = 0;
        for (size_t gi = 0; gi < pr->globals.count; gi++) {
            if (pr->globals.items[gi].name_len == 7 &&
                memcmp(pr->globals.items[gi].name, "package", 7) == 0 &&
                gref[gi]) { have_package = 1; break; }
        }
        if (need_any && have_package) {
            StrRef pkg_k    = strpool_add(&c->strs, "package", 7);
            StrRef loaded_k = strpool_add(&c->strs, "loaded",  6);
            wat_appendf(out,
                "    (local.set $tab (ref.cast (ref $LuaTable)\n"
                "      (call $tab_get\n"
                "        (ref.cast (ref $LuaTable) (call $tab_get\n"
                "          (ref.as_non_null (global.get $g_globals))\n"
                "          (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "            (i32.const %zu) (i32.const %zu)))))\n"
                "        (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                "          (i32.const %zu) (i32.const %zu))))))\n",
                pkg_k.offset, pkg_k.len, loaded_k.offset, loaded_k.len);
            for (size_t li = 0; li < sizeof(LIB_NAMES) / sizeof(LIB_NAMES[0]); li++) {
                size_t llen = strlen(LIB_NAMES[li]);
                int gi_found = -1;
                for (size_t gi = 0; gi < pr->globals.count; gi++) {
                    if (pr->globals.items[gi].name_len == llen &&
                        memcmp(pr->globals.items[gi].name, LIB_NAMES[li], llen) == 0 &&
                        gref[gi]) { gi_found = (int)gi; break; }
                }
                if (gi_found < 0) continue;
                StrRef name_k = strpool_add(&c->strs, LIB_NAMES[li], llen);
                wat_appendf(out,
                    "    (call $tab_set (local.get $tab)\n"
                    "      (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                    "        (i32.const %zu) (i32.const %zu)))\n"
                    "      (call $tab_get (ref.as_non_null (global.get $g_globals))\n"
                    "        (struct.new $LuaString (array.new_data $LuaArr $str_data\n"
                    "          (i32.const %zu) (i32.const %zu)))))\n",
                    name_k.offset, name_k.len, name_k.offset, name_k.len);
            }
        }
    }
}

/* Emit `$main`, the top-level chunk: locals (boxed/unboxed per escape
 * analysis), goto dispatch-id locals, the $stdlib_init call, eager boxing
 * of captured slots, then the body. */
static void emit_main_chunk(CG *c) {
    WatBuilder *out = c->w;
    const ParseResult *pr = c->pr;
    wat_append(out, "\n  ;; --- main (top-level chunk) ---\n");
    wat_append(out, "  (func $main (export \"main\")\n");
    c->cur_captured = pr->main_captured;
    c->cur_n_locals = pr->main_n_locals;
    c->cur_n_params = 0;
    c->cur_func_idx = -1;
    c->cur_func_slot = c->main_slot_func;
    c->cur_upval_func = NULL;
    unsigned char *isint = NULL, *isfloat = NULL;
    if (c->opt_int) {
        isint = calloc(pr->main_n_locals ? pr->main_n_locals : 1, 1);
        compute_int_slots(c, &pr->main_body, pr->main_n_locals, 0, pr->main_captured, isint, NULL);
        c->cur_is_int = isint;
        isfloat = calloc(pr->main_n_locals ? pr->main_n_locals : 1, 1);
        compute_float_slots(c, &pr->main_body, pr->main_n_locals, 0, pr->main_captured, isfloat, NULL);
    }
    c->cur_is_int = isint;
    c->cur_is_float = isfloat;
    /* Pre-pass before locals: dispatch ids must be assigned so the
     * $next_BID i32 locals can be declared up-front. */
    c->next_label_id = 0;
    la_block(c, &pr->main_body, NULL);

    for (int i = 0; i < pr->main_n_locals; i++) {
        if (isint && isint[i]) {
            wat_appendf(out, "    (local $L%d i64)\n", i);
        } else if (isfloat && isfloat[i]) {
            wat_appendf(out, "    (local $L%d f64)\n", i);
        } else if (pr->main_captured && pr->main_captured[i]) {
            wat_appendf(out, "    (local $L%d (ref $Box))\n", i);
        } else {
            wat_appendf(out, "    (local $L%d anyref)\n", i);
        }
    }
    wat_append(out, "    (local $tmp_any anyref)\n");
    wat_append(out, "    (local $tmp_args (ref null $ArgArr))\n");
    wat_append(out, "    (local $tmp_clo (ref null $LuaClosure))\n");
    wat_append(out, "    (local $tmp_callee anyref)\n");
    wat_append(out, "    (local $tmp_tab (ref null $LuaTable))\n");
    wat_append(out, "    (local $tmp_lhs_t (ref null $ArgArr))\n");
    wat_append(out, "    (local $tmp_lhs_k (ref null $ArgArr))\n");
    emit_for_scratch_locals(out, &pr->main_body);
    if (c->opt_int) {
        int lv = max_for_nesting(&pr->main_body);
        for (int d = 0; d < lv; d++)
            wat_appendf(out, "    (local $ifor_stop_%d i64) (local $ifor_step_%d i64)"
                            " (local $ifor_next_%d i64)\n", d, d, d);
    }
    {
        int bids[128]; int n = 0;
        collect_dispatch_ids(&pr->main_body, bids, &n, 128);
        for (int i = 0; i < n; i++) {
            wat_appendf(out, "    (local $next_%d i32)\n", bids[i]);
        }
    }
    wat_append(out, "    (call $stdlib_init)\n");
    /* Eager-init captured locals — see emit_user_function for the
     * rationale; main has no params, so every captured slot needs it. */
    for (int i = 0; i < pr->main_n_locals; i++) {
        if (pr->main_captured && pr->main_captured[i]) {
            wat_appendf(out,
                "    (local.set $L%d (struct.new $Box (ref.null any)))\n", i);
        }
    }

    if (c->ok) emit_block(c, &pr->main_body, 2);

    wat_append(out, "  )\n");
    c->cur_is_int = NULL;
    c->cur_is_float = NULL;
    c->cur_func_slot = NULL;
    c->cur_upval_func = NULL;
    free(isint);
    free(isfloat);
}

/* Emit the `$str_data` passive data segment: every interned byte of the
 * string pool, escaping quote/backslash/non-printables as \HH. */
static void emit_data_segment(CG *c) {
    WatBuilder *out = c->w;
    wat_append(out, "\n  ;; @@SECTION:data@@\n");
    wat_append(out, "  (data $str_data \"");
    for (size_t i = 0; i < c->strs.used; i++) {
        unsigned char b = (unsigned char)c->strs.bytes[i];
        if (b == '"' || b == '\\') wat_appendf(out, "\\%02x", b);
        else if (b >= 0x20 && b < 0x7f) {
            char tmp[2] = { (char)b, 0 };
            wat_append(out, tmp);
        } else {
            wat_appendf(out, "\\%02x", b);
        }
    }
    wat_append(out, "\")\n");
}

int codegen_module(const ParseResult *pr, const char *src_name,
                   int tree_shake, WatBuilder *out,
                   char *err, size_t errlen) {
    const char *slab_err = verify_literal_slab();
    if (slab_err) {
        snprintf(err, errlen,
                 "codegen: literal slab drift at \"%s\" — LITERAL_PREFIX and "
                 "the prelude.wat offset map disagree", slab_err);
        return 0;
    }

    CG c = { .w = out, .pr = pr, .ok = 1, .in_main = 1 };
    /* Integer-specialization PoC: opt-in via env so the default pipeline and
     * golden output are byte-for-byte unchanged. */
    c.opt_int = getenv("LUA2WASM_OPT_INT") != NULL;
    /* Whole-program pre-passes (opt_int): resolve direct-call targets (incl.
     * self-recursive/captured local functions), then infer per-function
     * param/return numeric types used to unbox the typed direct-call entries. */
    if (c.opt_int) {
        c.n_sigs = (int)pr->funcs.count;
        compute_func_bindings(&c, pr);
        infer_signatures(&c, pr);
    }
    strpool_add(&c.strs, LITERAL_PREFIX, LITERAL_PREFIX_LEN);

    wat_append(out, "(module\n");
    wat_append(out, PRELUDE);
    /* Section markers — purely cosmetic, but the playground's WAT viewer
     * splits the file by `;; @@SECTION:name@@` lines so users can collapse
     * the 5000-line runtime/stdlib block and focus on what their code
     * actually compiled to. Each emitted region from here on opens with
     * one of these markers; everything before the first marker is the
     * embedded prelude. */
    wat_append(out, "\n  ;; @@SECTION:stdlib-bindings@@\n");

    int nb = builtin_count();
    unsigned char *live = calloc((size_t)nb, 1);
    unsigned char *gref = calloc(pr->globals.count + 1, 1);
    if (!live || !gref) {
        snprintf(err, errlen, "out of memory");
        free(live); free(gref);
        return 0;
    }
    if (tree_shake) {
        compute_live_set(pr, nb, live, gref);
    } else {
        for (int i = 0; i < nb; i++) live[i] = 1;
        for (size_t i = 0; i < pr->globals.count; i++) gref[i] = 1;
    }

    /* elem declare for every live builtin func, so ref.func works in const init. */
    wat_append(out, "\n  (elem declare func");
    for (int i = 0; i < nb; i++) {
        if (!live[i]) continue;
        wat_appendf(out, " %s", builtin_func_name(i));
    }
    wat_append(out, ")\n");

    /* One wasm global per live builtin, pre-wrapping a closure. The global
     * name mirrors the WAT func name (sans $), so library builtins
     * (e.g. $builtin_math_type) don't collide with top-level ones
     * (e.g. $builtin_type) that happen to share a Lua-visible name. */
    for (int i = 0; i < nb; i++) {
        if (!live[i]) continue;
        wat_appendf(out,
            "  (global $g_%s (ref $LuaClosure)\n"
            "    (struct.new $LuaClosure (ref.func %s) (global.get $g_empty_upvals)))\n",
            builtin_func_name(i) + 1, builtin_func_name(i));
    }

    /* User-declared globals used to get a per-name $g_user_N wasm slot.
     * Since milestone 19 they live as entries in $g_globals (the Lua _G
     * table) and access goes through $tab_get / $tab_set. The parser
     * still tracks the global list for name resolution, but no wasm
     * globals are emitted for them. */

    /* $stdlib_init: builds math/string tables from the library builtins
     * and assigns them to the corresponding $g_user_N slots. */
    wat_append(out, "\n  (func $stdlib_init"
                    " (local $tab (ref $LuaTable))"
                    " (local $h (ref $LuaTable))\n");
    /* Initialize the metamethod-name globals from the strpool. Keys are
     * deduplicated by strpool_add. */
    static const struct { const char *name; const char *key; } MKEYS[] = {
        { "$g_mkey_index",      "__index"     },
        { "$g_mkey_newindex",   "__newindex"  },
        { "$g_mkey_add",        "__add"       },
        { "$g_mkey_sub",        "__sub"       },
        { "$g_mkey_mul",        "__mul"       },
        { "$g_mkey_div",        "__div"       },
        { "$g_mkey_mod",        "__mod"       },
        { "$g_mkey_pow",        "__pow"       },
        { "$g_mkey_unm",        "__unm"       },
        { "$g_mkey_idiv",       "__idiv"      },
        { "$g_mkey_band",       "__band"      },
        { "$g_mkey_bor",        "__bor"       },
        { "$g_mkey_bxor",       "__bxor"      },
        { "$g_mkey_shl",        "__shl"       },
        { "$g_mkey_shr",        "__shr"       },
        { "$g_mkey_bnot",       "__bnot"      },
        { "$g_mkey_concat",     "__concat"    },
        { "$g_mkey_len",        "__len"       },
        { "$g_mkey_eq",         "__eq"        },
        { "$g_mkey_lt",         "__lt"        },
        { "$g_mkey_le",         "__le"        },
        { "$g_mkey_call",       "__call"      },
        { "$g_mkey_close",      "__close"     },
        { "$g_mkey_tostring",   "__tostring"  },
        { "$g_mkey_metatable",  "__metatable" },
        { "$g_mkey_name",       "__name"      },
    };
    for (size_t k = 0; k < sizeof(MKEYS)/sizeof(MKEYS[0]); k++)
        emit_global_set_str(&c, MKEYS[k].name, MKEYS[k].key, strlen(MKEYS[k].key));
    /* "\t" used by print when joining args. */
    emit_global_set_str(&c, "$g_tab_str", "\t", 1);
    wat_appendf(out,
        "    (global.set $g_empty_str\n"
        "      (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0))))\n"
        "    (global.set $fmt_buf\n"
        "      (array.new $LuaArr (i32.const 0) (i32.const %d)))\n"
        "    (global.set $call_lines\n"
        "      (array.new $LineArr (i32.const 0) (i32.const 256)))\n",
        LUA_FMT_BUF_CAP);
    /* Source name used by error() and debug.traceback. */
    if (src_name) {
        emit_global_set_str(&c, "$g_src_name", src_name, strlen(src_name));
    } else {
        wat_append(out,
            "    (global.set $g_src_name\n"
            "      (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0))))\n");
    }
    /* Create the global-environment table $g_globals. Every Lua global
     * (user-declared, library, builtin) is installed as an entry below;
     * codegen emits $tab_get / $tab_set against this table for every
     * global read/write. */
    wat_append(out, "    (global.set $g_globals (call $tab_new))\n");

    /* Install every live top-level builtin (print, error, pcall, ...)
     * as a $g_globals entry. The underlying $g_<func_name> closure is
     * the value; user reassignment via `print = 42` writes a new entry,
     * leaving the original closure intact. */
    for (int bi = 0; bi < nb; bi++) {
        if (builtin_class(bi) != BLT_TOPLEVEL) continue;
        if (!live[bi]) continue;
        const char *key = builtin_name(bi);
        if (key[0] == '_') continue;   /* internal-only (e.g. _ipairs_iter) */
        char val[128];
        snprintf(val, sizeof(val), "(global.get $g_%s)", builtin_func_name(bi) + 1);
        emit_tab_set_str(&c, "(ref.as_non_null (global.get $g_globals))",
                         key, strlen(key), val);
    }

    /* Install _G as a self-reference. _ENV is the per-function "environment"
     * upvalue in Lua 5.4+; we don't implement that machinery, so we alias
     * it to _G — close enough for tests that just need _ENV to exist. */
    emit_tab_set_str(&c, "(ref.as_non_null (global.get $g_globals))",
                     "_G", 2, "(ref.as_non_null (global.get $g_globals))");
    emit_tab_set_str(&c, "(ref.as_non_null (global.get $g_globals))",
                     "_ENV", 4, "(ref.as_non_null (global.get $g_globals))");

    emit_library_tables(&c, gref, nb);

    emit_require_bridge(&c, gref);
    wat_append(out, "  )\n");

    wat_append(out, "\n  ;; @@SECTION:user-code@@\n");
    wat_append(out, "  ;; --- user functions ---\n");

    for (size_t i = 0; i < pr->funcs.count; i++) {
        emit_user_function(&c, pr->funcs.items[i], 0, 0);
        /* Direct-call fast entries (non-vararg only): _da returns the result
         * array (multi-value call contexts), _da1 returns a single anyref
         * (single-value contexts — no result-array allocation). */
        if (c.opt_int && !pr->funcs.items[i]->is_vararg) {
            emit_user_function(&c, pr->funcs.items[i], 1, 0);
            emit_user_function(&c, pr->funcs.items[i], 1, 1);
        }
        if (!c.ok) break;
    }

    if (c.ok) emit_main_chunk(&c);

    emit_data_segment(&c);

    wat_append(out, ")\n");

    if (!c.ok) {
        snprintf(err, errlen, "%s", c.err);
        free(c.strs.bytes);
        free(live); free(gref);
        free_func_bindings(&c);   /* before free_signatures: it reads c.n_sigs */
        free_signatures(&c);
        return 0;
    }
    free(c.strs.bytes);
    free(live); free(gref);
    free_func_bindings(&c);       /* before free_signatures: it reads c.n_sigs */
    free_signatures(&c);
    return 1;
}
