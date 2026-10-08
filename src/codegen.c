#include "codegen.h"
#include "builtins.h"
#include "xalloc.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* Size of the shared $fmt_buf scratch array (bytes). The runtime chunks
 * large reads/formats through it, so three sites must agree on this number:
 * the allocation below, the chunk bounds in runtime/prelude.wat, and
 * FMT_BUF_CAP in runtime/host-bindings.mjs. */
#define LUA_FMT_BUF_CAP 16384

/* Fixed-size codegen working-set caps. Each has an explicit overflow guard at
 * its use site that raises a codegen error (never silently truncates). */
#define MAX_BREAK_DEPTH  64  /* nested loop break targets */
#define MAX_BLOCK_LABELS 64  /* ::labels:: declared in one block */
#define MAX_DISPATCH_IDS 128 /* label-bearing blocks per function */

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
 *   $LuaFn     = func ((ref $LuaClosure) (ref $ArgArr)) -> (ref $ArgArr)
 *   $LuaFn1    = func ((ref $LuaClosure) anyref x4, i32 nargs) -> anyref
 *   $LuaClosure = struct { (ref $LuaFn) code, (ref $UpvalArr) upvals,
 *                          i32 weight, (ref $LuaFn1) fast }
 *
 * $code takes and returns argument arrays (any arity, all results); $fast is
 * the entry for single-result calls with at most FAST_MAX_ARGS arguments.
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

/* ----- string-literal pool -----
 *
 * An exact-whole-run index sits in front of the flat byte array so the common
 * case (the same key interned again — "__index", metamethod names, library
 * keys) resolves with a single hash probe + memcmp instead of an O(pool_bytes)
 * brute-force scan. The index is open-addressing FNV-1a, keyed by (the bytes
 * of) each previously-interned run and storing the offset that run resolved to.
 *
 * It is purely an accelerator: a hash miss falls back to strpool_scan, which
 * still finds any matching substring — including overlap with a longer string
 * or with the fixed LITERAL_PREFIX. Recorded offsets are always the
 * scan-resolved (lowest) offset, so dedup decisions and emitted byte offsets
 * are identical to the index-free version. */
typedef struct {
    size_t hash;   /* FNV-1a of the run's bytes (run hashed at insert time) */
    size_t offset; /* its resolved offset in the byte array */
    size_t len;    /* its length, for collision verification */
    int used;      /* slot occupied */
} StrIdxSlot;

typedef struct {
    char *bytes;
    size_t used;
    size_t cap;
    StrIdxSlot *idx;  /* open-addressing index; NULL until first insert */
    size_t idx_cap;   /* power-of-two capacity */
    size_t idx_count; /* occupied slots */
} StrPool;

typedef struct {
    size_t offset;
    size_t len;
} StrRef;

static size_t strpool_hash(const char *bytes, size_t len) {
    /* Compute the full 64-bit FNV-1a regardless of size_t width (size_t is
     * 32-bit on the wasm32 build) so the hash is target-independent; it only
     * drives bucket placement, but keeping it identical avoids surprises. */
    uint64_t h = 1469598103934665603u; /* FNV-1a 64-bit offset basis */
    for (size_t i = 0; i < len; i++) {
        h ^= (unsigned char)bytes[i];
        h *= 1099511628211u; /* FNV prime */
    }
    return (size_t)h;
}

/* Brute-force fallback: find an existing run of exactly these bytes anywhere
 * in the pool (substring overlap allowed). Returns SIZE_MAX if absent. */
static size_t strpool_scan(const StrPool *p, const char *bytes, size_t len) {
    if (len == 0) return 0; /* zero bytes read => any offset works */
    if (len > p->used) return SIZE_MAX;
    for (size_t i = 0; i + len <= p->used; i++)
        if (memcmp(p->bytes + i, bytes, len) == 0) return i;
    return SIZE_MAX;
}

/* Record a resolved (offset,len) run in the whole-run index. Grows/rehashes
 * the table when it passes ~70% load. */
static void strpool_index_put(StrPool *p, size_t hash, size_t offset, size_t len);
static void strpool_index_grow(StrPool *p) {
    size_t new_cap = p->idx_cap ? p->idx_cap * 2 : 64;
    StrIdxSlot *old = p->idx;
    size_t old_cap = p->idx_cap;
    p->idx = xmalloc(new_cap * sizeof *p->idx);
    memset(p->idx, 0, new_cap * sizeof *p->idx);
    p->idx_cap = new_cap;
    p->idx_count = 0;
    for (size_t i = 0; i < old_cap; i++)
        if (old[i].used) strpool_index_put(p, old[i].hash, old[i].offset, old[i].len);
    free(old);
}
static void strpool_index_put(StrPool *p, size_t hash, size_t offset, size_t len) {
    if (p->idx_cap == 0 || (p->idx_count + 1) * 10 >= p->idx_cap * 7)
        strpool_index_grow(p);
    size_t mask = p->idx_cap - 1;
    size_t i = hash & mask;
    while (p->idx[i].used) {
        if (p->idx[i].hash == hash && p->idx[i].len == len &&
            p->idx[i].offset == offset)
            return; /* already present */
        i = (i + 1) & mask;
    }
    p->idx[i] = (StrIdxSlot){.hash = hash, .offset = offset, .len = len, .used = 1};
    p->idx_count++;
}

/* Whole-run lookup via the index. Returns the run's offset, or SIZE_MAX on a
 * miss (caller falls back to strpool_scan). */
static size_t strpool_index_get(const StrPool *p, size_t hash,
                                const char *bytes, size_t len) {
    if (p->idx_cap == 0) return SIZE_MAX;
    size_t mask = p->idx_cap - 1;
    size_t i = hash & mask;
    while (p->idx[i].used) {
        if (p->idx[i].hash == hash && p->idx[i].len == len &&
            memcmp(p->bytes + p->idx[i].offset, bytes, len) == 0)
            return p->idx[i].offset;
        i = (i + 1) & mask;
    }
    return SIZE_MAX;
}

/* Intern a byte run, returning its (offset, len). Deduplicates: a run that
 * already appears in the pool is reused rather than re-appended, which keeps
 * repeated keys (metamethod names, "__index", library keys) single-copy in
 * the emitted $str_data segment. */
static StrRef strpool_add(StrPool *p, const char *bytes, size_t len) {
    if (len == 0) return (StrRef){.offset = 0, .len = 0};
    size_t hash = strpool_hash(bytes, len);
    size_t found = strpool_index_get(p, hash, bytes, len);
    if (found == SIZE_MAX) {
        /* Miss on the whole-run index: a substring overlap may still exist. */
        found = strpool_scan(p, bytes, len);
    }
    if (found != SIZE_MAX) {
        strpool_index_put(p, hash, found, len);
        return (StrRef){.offset = found, .len = len};
    }
    if (p->used + len > p->cap) {
        size_t new_cap = p->cap ? p->cap : 64;
        while (p->used + len > new_cap) new_cap *= 2;
        p->bytes = xrealloc(p->bytes, new_cap);
        p->cap = new_cap;
    }
    StrRef r = {.offset = p->used, .len = len};
    memcpy(p->bytes + p->used, bytes, len);
    p->used += len;
    strpool_index_put(p, hash, r.offset, len);
    return r;
}

static void strpool_free(StrPool *p) {
    free(p->bytes);
    free(p->idx);
    p->bytes = NULL;
    p->idx = NULL;
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
    Stmt **labels; /* pointers to STMT_LABEL nodes in this block */
    int n;
    int cur_idx; /* updated during walk: current stmt index */
    struct LabelScope *parent;
} LabelScope;

/* ----- whole-program numeric signatures (opt >= 1) -----
 * Parameter + return unboxing. In Lua 5.5 integer and float are distinct types
 * (3*3 == 9 but 3.0*3.0 == 9.0), so they are *incomparable*: a value seen as
 * both must stay boxed (NT_ANY) — unboxing it to one machine type would change
 * the result. The lattice is therefore NT_UNSET (top, "no evidence yet") above
 * the two incomparable concretes NT_INT / NT_FLOAT, above NT_ANY (bottom). */
typedef enum { NT_ANY = 0,
               NT_INT,
               NT_FLOAT,
               NT_UNSET } NumTy;
typedef struct {
    NumTy *param_ty; /* [n_params]; NULL when n_params == 0 */
    int n_params;
    NumTy ret_ty; /* single-value return type, NT_ANY if not monomorphic */
    int has_site; /* a direct-call site somewhere targets this function */
} FuncSig;

/* The wasm functions one Lua function compiles to. */
typedef enum {
    ENTRY_GENERIC, /* $user_N: (closure, argument array) -> result array — the closure's $code */
    ENTRY_FAST,    /* $user_N_f: $LuaFn1 — up to FAST_MAX_ARGS arguments in registers, one result */
    ENTRY_DIRECT,  /* $user_N_da: typed arguments, result array (multi-value direct-call sites) */
    ENTRY_DIRECT1, /* $user_N_da1: typed arguments, one typed result (single-value sites) */
} FnEntry;

/* ----- codegen context ----- */
typedef struct {
    WatBuilder *w;
    const ParseResult *pr; /* for VAR_GLOBAL name lookup */
    StrPool strs;
    /* Hoisted constant strings: every compile-time string literal or key of at
     * most KSTR_MAX bytes becomes one immutable module global
     * ($kstr_<offset>_<len>) carrying its bytes (array.new_fixed) and its
     * precomputed hash — allocated once at instantiation, not at every
     * evaluation, and the same object at every site that spells the same
     * literal (so table lookups hit on identity). `kstrs` dedups the bytes;
     * `kstr_list` records each distinct (offset,len) for the declarations
     * emitted at the module tail. Longer literals stay in $str_data. */
    StrPool kstrs;
    StrRef *kstr_list;
    size_t kstr_n, kstr_cap;
    /* Runtime function the stdlib bootstrap uses to install _G / library
     * entries: "$tab_bootstrap_set" (append-only, lets DCE drop the table
     * write path) when the program writes no tables of its own, else the
     * general "$tab_set". Chosen in codegen_module; see program_writes_table. */
    const char *tab_set_fn;
    int next_label;
    int in_main;                       /* 1 while emitting $main body, 0 inside user fn */
    int break_labels[MAX_BREAK_DEPTH]; /* break targets for nested while/for/repeat */
    int break_depth;
    /* To-be-closed (<close>) handling for the function being emitted. All
     * closing is data-driven through a per-activation $Tbc stack at runtime;
     * codegen only tracks how many to-be-closed vars are lexically in scope so
     * it can tell $close_upto a target depth. `close_count` is the live count
     * at the current emission point (== runtime $tbc.len, since Lua forbids
     * jumping into a to-be-closed scope). `break_close_count[d]` snapshots
     * close_count at loop d's entry, so `break` closes only the loop's own
     * vars. The function prologue allocates $tbc only when the body declares a
     * to-be-closed variable; emit_close_upto is reached only when count>0, so
     * $tbc is always present where used. */
    int close_count;
    int break_close_count[MAX_BREAK_DEPTH];
    int for_depth; /* nesting depth of numeric/generic for-loops;
                    * indexes per-level $for_* scratch locals so a
                    * nested loop can't clobber the enclosing loop's
                    * stop/step or iterator state */
    /* Escape-analysis context for the currently-emitted body: cur_captured[s]
     * != 0 means slot s must be heap-boxed (some descendant function captures
     * it); cur_captured[s] == 0 lets the slot be a plain wasm anyref. Set
     * before emitting either a user function body or the main chunk. */
    const unsigned char *cur_captured;
    int cur_n_locals;
    /* Integer/float specialization (on by default; -O0 disables). When on,
     * cur_is_int[s] != 0 marks a local slot proven to hold only integers; it
     * is declared as an unboxed i64 and integer arithmetic on it is emitted as
     * inline i64 ops, boxed to a Lua value only at use-site boundaries. */
    int opt_int;
    const unsigned char *cur_is_int;
    const unsigned char *cur_is_float; /* slots proven float-only -> unboxed f64 */
    /* Maybe-typed slots (docs/design/22-maybe-typed-locals.md): cur_is_maybe[s]
     * != 0 marks a local emitted as a (tag, i64, f64, anyref) quadruple that
     * speculates int/float with a boxed fallback. mt_depth is the number of
     * lowering temporaries in use at the current emission point; mt_max the
     * count declared for the function (a pre-pass upper bound). */
    const unsigned char *cur_is_maybe;
    /* During compute_maybe_slots: candidates whose only numeric use is as a
     * table key (see maybe_kill_stmt). */
    const unsigned char *maybe_key_only;
    int mt_depth;
    int mt_max;
    /* Direct-call PoC (lever 3): cur_func_slot[s] != NULL means local slot s is
     * statically bound to that LuaFunc (a non-captured, never-reassigned local
     * function), so a call f(args) of matching arity can skip the $ArgArr and
     * invoke the function's direct-args entry $user_N_da. */
    const LuaFunc **cur_func_slot;
    FnEntry entry;     /* the entry whose body is being emitted (GENERIC for main) */
    int n_ctor_shapes; /* table-constructor sites with a cached shape ($cshape_N) */
    int n_ics;         /* constant-key access sites with an inline cache ($ic_N) */
    int n_mics;        /* method-call sites with an inline cache ($mic_N) */
    NumTy cur_ret_ty;  /* result type of the $user_N_da1 body being emitted */
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
    int n_binds;                    /* length of bind_slot/bind_upval, set by their allocator */
    int cur_func_idx;               /* func_idx of the body being emitted; -1 = main */
    const LuaFunc **cur_upval_func; /* upvalue->LuaFunc map for that body */
    int cur_n_params;
    /* goto/label state */
    int next_label_id;       /* fresh per function body */
    LabelScope *label_scope; /* innermost first */
    /* When set, the program observes no runtime state ($stdlib_init builds
     * nothing it can reach), so $main omits the `(call $stdlib_init)` and DCE
     * cascade-drops the runtime. Set from compute_live_set's needs_runtime. */
    int skip_runtime_init;
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
    /* Record the live to-be-closed count at loop entry so `break` closes only
     * the <close> locals declared inside this loop. */
    c->break_close_count[c->break_depth] = c->close_count;
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
    Stmt *labels[MAX_BLOCK_LABELS]; /* up to MAX_BLOCK_LABELS labels per block */
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
    case STMT_DO: la_block(c, &s->as.do_stmt.body, scope); break;
    case STMT_WHILE: la_block(c, &s->as.while_stmt.body, scope); break;
    case STMT_REPEAT: la_block(c, &s->as.repeat.body, scope); break;
    case STMT_FOR_NUM: la_block(c, &s->as.for_num.body, scope); break;
    case STMT_FOR_GEN: la_block(c, &s->as.for_gen.body, scope); break;
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
    LabelAnalysisScope scope = {.n = 0, .parent = parent};
    /* Pass 1: collect labels, dedup, assign ids. */
    for (size_t i = 0; i < b->count; i++) {
        Stmt *st = b->items[i];
        if (st->kind != STMT_LABEL) continue;
        if (scope.n >= MAX_BLOCK_LABELS) {
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
            /* The goto closes to-be-closed vars down to the target's depth
             * (stamped by la_close_bases, which runs before this pass). */
            st->as.label.close_base = lab->as.label.close_base;
        } else if (st->kind != STMT_LABEL) {
            la_recurse_stmt(c, st, &scope);
        }
    }
}

static int for_gen_has_closing(const Stmt *s);

/* Stamp every STMT_LABEL with the count of to-be-closed variables in scope at
 * that label (`running`), walking statements in source order. Runs before
 * la_block, which copies each label's base onto the gotos that target it.
 * Does not descend into nested function bodies (they get their own pass). */
static void la_close_bases(const Block *b, int running) {
    for (size_t i = 0; i < b->count; i++) {
        Stmt *s = b->items[i];
        switch (s->kind) {
        case STMT_LABEL:
            s->as.label.close_base = running;
            break;
        case STMT_LOCAL:
            if (s->as.local.attribs)
                for (int j = 0; j < s->as.local.n_names; j++)
                    if (s->as.local.attribs[j] == 2) running++;
            break;
        case STMT_DO: la_close_bases(&s->as.do_stmt.body, running); break;
        case STMT_WHILE: la_close_bases(&s->as.while_stmt.body, running); break;
        case STMT_REPEAT: la_close_bases(&s->as.repeat.body, running); break;
        case STMT_FOR_NUM: la_close_bases(&s->as.for_num.body, running); break;
        case STMT_FOR_GEN:
            /* The generic-for closing value is in scope for the loop body. */
            la_close_bases(&s->as.for_gen.body, running + for_gen_has_closing(s));
            break;
        case STMT_IF:
            for (size_t a = 0; a < s->as.if_stmt.narms; a++)
                la_close_bases(&s->as.if_stmt.arms[a].body, running);
            if (s->as.if_stmt.has_else)
                la_close_bases(&s->as.if_stmt.else_body, running);
            break;
        default: break;
        }
    }
}

static void emit_indent(CG *c, int depth) {
    for (int i = 0; i < depth; i++) wat_append(c->w, "  ");
}

/* One line of WAT at `depth`: the indentation, then `text` (which carries
 * its own trailing newline, if any). */
static void emit_line(CG *c, int depth, const char *text) {
    emit_indent(c, depth);
    wat_append(c->w, text);
}

/* printf-style emit_line. */
[[gnu::format(printf, 3, 4)]] static void emit_linef(CG *c, int depth, const char *fmt, ...) {
    va_list ap;
    emit_indent(c, depth);
    va_start(ap, fmt);
    wat_vappendf(c->w, fmt, ap);
    va_end(ap);
}

static int i31_fits(int64_t v) {
    return v >= -(int64_t)0x40000000 && v < (int64_t)0x40000000;
}

/* ----- forward decls ----- */
static void emit_expr(CG *c, const Expr *e, int depth);
static void emit_block(CG *c, const Block *b, int depth);
static void emit_stmt(CG *c, const Stmt *s, int depth);
static void emit_block_stmts(CG *c, const Block *b, int depth);
static void emit_close_upto(CG *c, int target, const char *err_wat, int depth);
static int expr_is_int(CG *c, const Expr *e);
static void emit_int_expr(CG *c, const Expr *e, int depth);
static int expr_is_float(CG *c, const Expr *e);
static void emit_float_expr(CG *c, const Expr *e, int depth);
static int slot_is_maybe(const CG *c, int slot);
static int expr_involves_maybe(CG *c, const Expr *e);
static void emit_maybe_store(CG *c, int slot, const Expr *e, int depth);
static void emit_maybe_boxed(CG *c, const Expr *e, int depth);
static void emit_maybe_cmp_block(CG *c, const Expr *e, int depth);
static void emit_maybe_slot_box(CG *c, int slot, int depth);
static void resolve_upval_origin(CG *c, int func_idx, int u, int *of, int *os);

/* A cell is the four-part view of a maybe value used by the lowering: read
 * expressions for tag / i64 / f64 / boxed, plus the local names to write when
 * the cell is a destination (a slot or a temporary). An *immediate* cell has
 * no write targets: a numeric literal, or a provably typed local, appears in
 * the tag switch as constants / a plain local.get and costs no temporary. */
typedef struct {
    char t[48], i[48], f[48], b[48];     /* read expressions */
    char st[16], si[16], sf[16], sb[16]; /* write targets ("" for an immediate) */
} MCell;
static MCell mcell_slot(int s) {
    MCell m;
    snprintf(m.st, sizeof m.st, "$Lt%d", s);
    snprintf(m.si, sizeof m.si, "$Li%d", s);
    snprintf(m.sf, sizeof m.sf, "$Lf%d", s);
    snprintf(m.sb, sizeof m.sb, "$L%d", s);
    snprintf(m.t, sizeof m.t, "(local.get %s)", m.st);
    snprintf(m.i, sizeof m.i, "(local.get %s)", m.si);
    snprintf(m.f, sizeof m.f, "(local.get %s)", m.sf);
    snprintf(m.b, sizeof m.b, "(local.get %s)", m.sb);
    return m;
}
static MCell mcell_tmp(int k) {
    MCell m;
    snprintf(m.st, sizeof m.st, "$mg%d", k);
    snprintf(m.si, sizeof m.si, "$mi%d", k);
    snprintf(m.sf, sizeof m.sf, "$mf%d", k);
    snprintf(m.sb, sizeof m.sb, "$mt%d", k);
    snprintf(m.t, sizeof m.t, "(local.get %s)", m.st);
    snprintf(m.i, sizeof m.i, "(local.get %s)", m.si);
    snprintf(m.f, sizeof m.f, "(local.get %s)", m.sf);
    snprintf(m.b, sizeof m.b, "(local.get %s)", m.sb);
    return m;
}
static MCell mcell_imm_int(int64_t v) {
    MCell m = {0};
    snprintf(m.t, sizeof m.t, "(i32.const 1)");
    snprintf(m.i, sizeof m.i, "(i64.const %lld)", (long long)v);
    snprintf(m.f, sizeof m.f, "(f64.const 0)");
    snprintf(m.b, sizeof m.b, "(ref.null any)");
    return m;
}
static MCell mcell_imm_float(double v) {
    MCell m = {0};
    snprintf(m.t, sizeof m.t, "(i32.const 2)");
    snprintf(m.i, sizeof m.i, "(i64.const 0)");
    snprintf(m.f, sizeof m.f, "(f64.const %.17g)", v);
    snprintf(m.b, sizeof m.b, "(ref.null any)");
    return m;
}
static MCell mcell_typed_local(int slot, int is_float) {
    MCell m = {0};
    snprintf(m.t, sizeof m.t, "(i32.const %d)", is_float ? 2 : 1);
    snprintf(m.i, sizeof m.i, is_float ? "(i64.const 0)" : "(local.get $L%d)", slot);
    snprintf(m.f, sizeof m.f, is_float ? "(local.get $L%d)" : "(f64.const 0)", slot);
    snprintf(m.b, sizeof m.b, "(ref.null any)");
    return m;
}

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
    emit_linef(c, depth, "(struct.new $LuaFloat (f64.const %.17g))\n", v);
}

/* Longest constant string that is hoisted into a module global; longer
 * literals are allocated from $str_data at each evaluation. Bounded so an
 * array.new_fixed initializer never approaches engine operand limits. */
#define KSTR_MAX 256

/* FNV-1a 32-bit — the same function as $str_hash in runtime/prelude.wat
 * (0 is stored as 1 there, so mirror that). A constant's hash is baked into
 * its global so the runtime never has to compute it. */
static int32_t kstr_hash(const char *bytes, size_t len) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < len; i++) h = (h ^ (unsigned char)bytes[i]) * 16777619u;
    if (h == 0) h = 1;
    return (int32_t)h;
}

/* Metamethod-name key globals: immutable, const-initialized at module level
 * (not assigned in $stdlib_init) so DCE drops the ones whose reader-helpers
 * are dead — e.g. a fully-specialized integer program never reaches $lua_add
 * and so doesn't need $g_mkey_add. A user literal spelling one of these names
 * (`Vec.__index = Vec`) resolves to the same global (see kstr_name), so the
 * runtime's probe and the user's key are one object. */
static const struct {
    const char *name;
    const char *key;
} MKEYS[] = {
    {"$g_mkey_index", "__index"},
    {"$g_mkey_newindex", "__newindex"},
    {"$g_mkey_add", "__add"},
    {"$g_mkey_sub", "__sub"},
    {"$g_mkey_mul", "__mul"},
    {"$g_mkey_div", "__div"},
    {"$g_mkey_mod", "__mod"},
    {"$g_mkey_pow", "__pow"},
    {"$g_mkey_unm", "__unm"},
    {"$g_mkey_idiv", "__idiv"},
    {"$g_mkey_band", "__band"},
    {"$g_mkey_bor", "__bor"},
    {"$g_mkey_bxor", "__bxor"},
    {"$g_mkey_shl", "__shl"},
    {"$g_mkey_shr", "__shr"},
    {"$g_mkey_bnot", "__bnot"},
    {"$g_mkey_concat", "__concat"},
    {"$g_mkey_len", "__len"},
    {"$g_mkey_eq", "__eq"},
    {"$g_mkey_lt", "__lt"},
    {"$g_mkey_le", "__le"},
    {"$g_mkey_call", "__call"},
    {"$g_mkey_close", "__close"},
    {"$g_mkey_tostring", "__tostring"},
    {"$g_mkey_metatable", "__metatable"},
    {"$g_mkey_name", "__name"},
    /* type() results ($basic_type_name): a literal type name in the program
     * is the very string type() returns, so `type(x) == "number"` compares by
     * identity and type() allocates nothing. */
    {"$g_tname_nil", "nil"},
    {"$g_tname_boolean", "boolean"},
    {"$g_tname_number", "number"},
    {"$g_tname_string", "string"},
    {"$g_tname_table", "table"},
    {"$g_tname_function", "function"},
};
#define N_MKEYS (sizeof(MKEYS) / sizeof(MKEYS[0]))

/* The global that holds constant string `bytes` (len <= KSTR_MAX), registering
 * it for declaration at the module tail. Metamethod names and the empty string
 * map to the prelude-visible globals. Returns `buf` or a static name. */
static const char *kstr_name(CG *c, const char *bytes, size_t len, char *buf, size_t bufsz) {
    if (len == 0) return "$g_empty_str";
    for (size_t k = 0; k < N_MKEYS; k++)
        if (strlen(MKEYS[k].key) == len && memcmp(MKEYS[k].key, bytes, len) == 0)
            return MKEYS[k].name;
    StrRef r = strpool_add(&c->kstrs, bytes, len);
    size_t i;
    for (i = 0; i < c->kstr_n; i++)
        if (c->kstr_list[i].offset == r.offset && c->kstr_list[i].len == r.len) break;
    if (i == c->kstr_n) {
        if (c->kstr_n == c->kstr_cap) {
            c->kstr_cap = c->kstr_cap ? c->kstr_cap * 2 : 64;
            c->kstr_list = xrealloc(c->kstr_list, c->kstr_cap * sizeof *c->kstr_list);
        }
        c->kstr_list[c->kstr_n++] = r;
    }
    snprintf(buf, bufsz, "$kstr_%zu_%zu", r.offset, r.len);
    return buf;
}

/* The one canonical expression for a constant string in value position:
 * `(global.get $kstr_…)` for a hoistable literal, else a fresh
 * `(struct.new $LuaString (array.new_data …) (i32.const 0))` from $str_data.
 * Written into `buf` (no indentation, no newline). */
static const char *kstr_expr(CG *c, const char *bytes, size_t len, char *buf, size_t bufsz) {
    if (len <= KSTR_MAX) {
        char nb[64];
        snprintf(buf, bufsz, "(global.get %s)", kstr_name(c, bytes, len, nb, sizeof nb));
    } else {
        StrRef r = strpool_add(&c->strs, bytes, len);
        snprintf(buf, bufsz,
                 "(struct.new $LuaString (array.new_data $LuaArr $str_data "
                 "(i32.const %zu) (i32.const %zu)) (i32.const 0))",
                 r.offset, r.len);
    }
    return buf;
}

/* A fresh inline cache for a constant-key access site, as the expression
 * passing it (`(global.get $ic_N)`), or NULL when the specializer is off
 * (-O0 keeps the uncached setters/getters). */
static const char *ic_new(CG *c, char *buf, size_t bufsz) {
    if (!c->opt_int) return NULL;
    snprintf(buf, bufsz, "(global.get $ic_%d)", c->n_ics++);
    return buf;
}

/* Emit a constant string as one folded line indented to `depth`. */
static void emit_string_literal(CG *c, const char *bytes, size_t len, int depth) {
    char eb[160];
    emit_linef(c, depth, "%s\n", kstr_expr(c, bytes, len, eb, sizeof eb));
}

/* ----- variable read / write -----
 * VAR_UPVAL is only emitted inside user functions (parser guarantees this:
 * main has no upvalues to capture).
 */
/* Emit the constant-string key carrying the name of a global (one line, no
 * indentation). Used by every global read/write. */
static void emit_global_key(CG *c, const char *name, size_t name_len) {
    char eb[160];
    wat_appendf(c->w, "%s\n", kstr_expr(c, name, name_len, eb, sizeof eb));
}

/* `(call <c->tab_set_fn> (local.get $tgt) "key" (global.get $g_<glob>))` — the
 * shape used everywhere stdlib_init wires a builtin closure into a library
 * table or a sub-table like a file handle. The setter is $tab_bootstrap_set or
 * $tab_set per the DCE gate (see program_writes_table). */
static void emit_tab_set_global(CG *c, const char *tgt, const char *key, size_t klen,
                                const char *glob) {
    char eb[160];
    wat_appendf(c->w, "    (call %s (local.get %s) %s (global.get $g_%s))\n", c->tab_set_fn, tgt,
                kstr_expr(c, key, klen, eb, sizeof eb), glob);
}

/* `(global <glob> (ref $LuaString) "<s>")` — an immutable module-level global
 * holding a Lua string whose bytes are inlined via array.new_fixed (a constant
 * expression, unlike array.new_data, so it's valid in a global initializer),
 * with its hash precomputed. Declaring a constant string this way instead of
 * assigning it in $stdlib_init lets DCE drop it when no reachable code reads
 * it. */
static void emit_global_const_str(CG *c, const char *glob, const char *s, size_t len) {
    wat_appendf(c->w,
                "  (global %s (ref $LuaString)\n"
                "    (struct.new $LuaString (array.new_fixed $LuaArr %zu",
                glob, len);
    for (size_t i = 0; i < len; i++) wat_appendf(c->w, " (i32.const %u)", (unsigned char)s[i]);
    wat_appendf(c->w, ") (i32.const %d)))\n", (int)kstr_hash(s, len));
}

/* Declare every hoisted constant string registered through kstr_name. */
static void emit_kstr_globals(CG *c) {
    if (c->kstr_n == 0) return;
    wat_append(c->w, "\n  ;; @@SECTION:kstr@@ hoisted constant strings (bytes + precomputed hash)\n");
    for (size_t i = 0; i < c->kstr_n; i++) {
        char nb[64];
        StrRef r = c->kstr_list[i];
        snprintf(nb, sizeof nb, "$kstr_%zu_%zu", r.offset, r.len);
        emit_global_const_str(c, nb, c->kstrs.bytes + r.offset, r.len);
    }
}

/* `(call <c->tab_set_fn> <target> "<key>" <value>)` where <target> and <value>
 * are complete WAT expressions. The general form behind every stdlib_init table
 * install whose value isn't itself a plain string. */
static void emit_tab_set_str(CG *c, const char *target,
                             const char *key, size_t klen, const char *value) {
    char eb[160];
    wat_appendf(c->w, "    (call %s %s %s\n      %s)\n", c->tab_set_fn, target,
                kstr_expr(c, key, klen, eb, sizeof eb), value);
}

/* `(call <c->tab_set_fn> <target> "<key>" "<val>")` — install a string-valued
 * entry; both key and value are constants. */
static void emit_tab_set_strval(CG *c, const char *target, const char *key,
                                size_t klen, const char *val, size_t vlen) {
    char kb[160], vb[160];
    wat_appendf(c->w, "    (call %s %s %s %s)\n", c->tab_set_fn, target,
                kstr_expr(c, key, klen, kb, sizeof kb), kstr_expr(c, val, vlen, vb, sizeof vb));
}

static void emit_global_read(CG *c, const char *name, size_t name_len, int depth) {
    emit_line(c, depth, "(call $tab_get (ref.as_non_null (global.get $g_globals))\n");
    emit_indent(c, depth + 1);
    emit_global_key(c, name, name_len);
    emit_line(c, depth, ")\n");
}

static void emit_var_read(CG *c, VarKind kind, int idx, int depth) {
    switch (kind) {
    case VAR_LOCAL:
        if (slot_is_maybe(c, idx)) {
            emit_maybe_slot_box(c, idx, depth);
            break;
        }
        emit_indent(c, depth);
        if (slot_is_boxed(c, idx)) {
            wat_appendf(c->w, "(struct.get $Box $v (local.get $L%d))\n", idx);
        } else {
            wat_appendf(c->w, "(local.get $L%d)\n", idx);
        }
        break;
    case VAR_UPVAL:
        emit_linef(c, depth, "(struct.get $Box $v (array.get $UpvalArr "
                             "(struct.get $LuaClosure $upvals (local.get $closure)) "
                             "(i32.const %d)))\n",
                   idx);
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
                    "(i32.const %d))\n",
                    idx);
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
            if (slot_is_maybe(c, t->as.var.idx)) {
                /* The analysis kills a maybe slot on every multi-value store
                 * path, so only single stores (emit_maybe_store) reach one. */
                cg_error(c, "internal: maybe-typed slot in a generic store");
                return;
            }
            if (slot_is_boxed(c, t->as.var.idx)) {
                emit_line(c, depth, "(struct.set $Box $v\n");
                emit_box_ref(c, VAR_LOCAL, t->as.var.idx, depth + 1);
            } else {
                emit_linef(c, depth, "(local.set $L%d\n", t->as.var.idx);
            }
            break;
        case VAR_UPVAL:
            emit_line(c, depth, "(struct.set $Box $v\n");
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
            emit_line(c, depth, "(call $tab_set (ref.as_non_null (global.get $g_globals))\n");
            emit_indent(c, depth + 1);
            emit_global_key(c, name, name_len);
            break;
        }
        }
    } else if (t->as.index.key->kind == EXPR_STRING && t->as.index.key->as.s.len <= KSTR_MAX) {
        /* Constant string key: $lua_tabset_sk stores to the hash part directly
         * when there is no metatable, else dispatches __newindex; the
         * inline-cached $lua_tabset_ic first tries the site's cached slot. */
        char icb[48];
        const char *ic = ic_new(c, icb, sizeof icb);
        emit_indent(c, depth);
        if (ic) wat_appendf(c->w, "(call $lua_tabset_ic %s\n", ic);
        else wat_append(c->w, "(call $lua_tabset_sk\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_string_literal(c, t->as.index.key->as.s.bytes, t->as.index.key->as.s.len, depth + 1);
    } else if (t->as.index.key->kind == EXPR_VAR && t->as.index.key->as.var.kind == VAR_LOCAL &&
               slot_is_maybe(c, t->as.index.key->as.var.idx)) {
        MCell k = mcell_slot(t->as.index.key->as.var.idx);
        emit_line(c, depth, "(call $lua_tabset_mk\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_linef(c, depth + 1, "%s %s %s %s\n", k.t, k.i, k.f, k.b);
    } else if (c->opt_int && expr_is_int(c, t->as.index.key)) {
        /* Int-typed key: $lua_tabset_ik takes the raw i64 (no make_int /
         * $as_arr_key) and still dispatches __newindex. The value is emitted
         * by the caller between open and close. */
        emit_line(c, depth, "(call $lua_tabset_ik\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_int_expr(c, t->as.index.key, depth + 1);
    } else {
        /* User-code assignment goes through \$lua_tabset so __newindex
         * has a chance to fire. Table constructors emit \$tab_set
         * directly since freshly built tables have no metatable. */
        emit_line(c, depth, "(call $lua_tabset\n");
        emit_expr(c, t->as.index.table, depth + 1);
        emit_expr(c, t->as.index.key, depth + 1);
    }
}
/* Close an emit_target_open() expression. The target is the same one passed to
 * open, but every target shape closes with a single `)`, so it isn't needed. */
static void emit_target_close(CG *c, int depth) {
    emit_line(c, depth, ")\n");
}

/* ----- binary / unary ops ----- */
static const char *binop_helper(BinOp op) {
    switch (op) {
    case BIN_ADD: return "$lua_add";
    case BIN_SUB: return "$lua_sub";
    case BIN_MUL: return "$lua_mul";
    case BIN_DIV: return "$lua_div";
    case BIN_FDIV: return "$lua_fdiv";
    case BIN_MOD: return "$lua_mod";
    case BIN_POW: return "$lua_pow";
    case BIN_CONCAT: return "$lua_concat";
    case BIN_EQ: return "$lua_eq";
    case BIN_NEQ: return "$lua_neq";
    case BIN_LT: return "$lua_lt";
    case BIN_LE: return "$lua_le";
    case BIN_GT: return "$lua_gt";
    case BIN_GE: return "$lua_ge";
    case BIN_BAND: return "$lua_band";
    case BIN_BOR: return "$lua_bor";
    case BIN_BXOR: return "$lua_bxor";
    case BIN_SHL: return "$lua_shl";
    case BIN_SHR: return "$lua_shr";
    /* BIN_AND / BIN_OR are short-circuiting and handled in emit_binop
     * before reaching here; any other value is a codegen bug. */
    default: return NULL;
    }
}

/* ----- comparisons ----- */

/* Every spelling of one comparison operator: the native i64/f64 opcodes, and
 * the prelude helpers comparing an int with a float exactly — Lua compares
 * them exactly, which converting the integer to f64 does not preserve beyond
 * 2^53 — taking their operands in source order. `~=` has no helper of its
 * own: it negates the `==` one. */
typedef struct {
    const char *i64, *f64;
    const char *int_float, *float_int;
    int negate;
} CmpOp;

static int is_cmp_op(BinOp op) {
    switch (op) {
    case BIN_LT:
    case BIN_LE:
    case BIN_GT:
    case BIN_GE:
    case BIN_EQ:
    case BIN_NEQ: return 1;
    default: return 0;
    }
}

/* The spellings of comparison operator `op` (is_cmp_op). */
static const CmpOp *cmp_op(BinOp op) {
    static const CmpOp LT = {"i64.lt_s", "f64.lt", "$int_lt_float", "$float_lt_int", 0};
    static const CmpOp LE = {"i64.le_s", "f64.le", "$int_le_float", "$float_le_int", 0};
    static const CmpOp GT = {"i64.gt_s", "f64.gt", "$int_gt_float", "$float_gt_int", 0};
    static const CmpOp GE = {"i64.ge_s", "f64.ge", "$int_ge_float", "$float_ge_int", 0};
    static const CmpOp EQ = {"i64.eq", "f64.eq", "$int_eq_float", "$float_eq_int", 0};
    static const CmpOp NE = {"i64.ne", "f64.ne", "$int_eq_float", "$float_eq_int", 1};
    switch (op) {
    case BIN_LT: return &LT;
    case BIN_LE: return &LE;
    case BIN_GT: return &GT;
    case BIN_GE: return &GE;
    case BIN_EQ: return &EQ;
    default: return &NE;
    }
}

/* An integer literal that converts to f64 exactly (|v| <= 2^53), so comparing
 * it with a float as two doubles gives Lua's exact int-vs-float answer. */
static int expr_is_exact_f64_int_literal(const Expr *e) {
    const int64_t lim = (int64_t)1 << 53;
    return e->kind == EXPR_INT && e->as.i_val >= -lim && e->as.i_val <= lim;
}

/* The operand types of a comparison whose operands are both unboxed numbers
 * (CMP_NONE when they aren't). */
typedef enum { CMP_NONE,
               CMP_INT,
               CMP_FLOAT,
               CMP_INT_FLOAT,
               CMP_FLOAT_INT } CmpKind;

static CmpKind cmp_numeric_kind(CG *c, const Expr *e) {
    if (!c->opt_int || e->kind != EXPR_BINOP || !is_cmp_op(e->as.binop.op)) return CMP_NONE;
    const Expr *l = e->as.binop.lhs, *r = e->as.binop.rhs;
    if (expr_is_int(c, l) && expr_is_int(c, r)) return CMP_INT;
    if (expr_is_float(c, l) && expr_is_float(c, r)) return CMP_FLOAT;
    if (expr_is_int(c, l) && expr_is_float(c, r)) return CMP_INT_FLOAT;
    if (expr_is_float(c, l) && expr_is_int(c, r)) return CMP_FLOAT_INT;
    return CMP_NONE;
}

/* Emit a typed numeric comparison (cmp_numeric_kind != CMP_NONE) as a raw
 * i32. An int-vs-float one is an f64 compare when the integer is a literal
 * that converts exactly, else the exact mixed helper. */
static void emit_cmp_i32(CG *c, const Expr *e, int depth, CmpKind kind) {
    const CmpOp *op = cmp_op(e->as.binop.op);
    const Expr *l = e->as.binop.lhs, *r = e->as.binop.rhs;
    if (kind == CMP_INT_FLOAT || kind == CMP_FLOAT_INT) {
        int int_left = kind == CMP_INT_FLOAT;
        if (expr_is_exact_f64_int_literal(int_left ? l : r)) {
            emit_linef(c, depth, "(%s\n", op->f64);
            emit_num_as_f64(c, l, depth + 1);
            emit_num_as_f64(c, r, depth + 1);
        } else {
            emit_linef(c, depth, "%s(call %s\n", op->negate ? "(i32.eqz " : "",
                       int_left ? op->int_float : op->float_int);
            if (int_left) {
                emit_int_expr(c, l, depth + 1);
                emit_float_expr(c, r, depth + 1);
            } else {
                emit_float_expr(c, l, depth + 1);
                emit_int_expr(c, r, depth + 1);
            }
            if (op->negate) emit_line(c, depth, ")\n");
        }
        emit_line(c, depth, ")\n");
        return;
    }
    emit_linef(c, depth, "(%s\n", kind == CMP_INT ? op->i64 : op->f64);
    if (kind == CMP_INT) {
        emit_int_expr(c, e->as.binop.lhs, depth + 1);
        emit_int_expr(c, e->as.binop.rhs, depth + 1);
    } else {
        emit_num_as_f64(c, e->as.binop.lhs, depth + 1);
        emit_num_as_f64(c, e->as.binop.rhs, depth + 1);
    }
    emit_line(c, depth, ")\n");
}

/* Emit `e` as an i32 truthiness (0/1). A numeric comparison becomes a direct
 * iXX/fXX compare, skipping the boxed boolean and $lua_truthy. */
static void emit_truthy(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_BINOP && is_cmp_op(e->as.binop.op) && expr_involves_maybe(c, e)) {
        emit_maybe_cmp_block(c, e, depth);
        return;
    }
    CmpKind k = cmp_numeric_kind(c, e);
    if (k) {
        emit_cmp_i32(c, e, depth, k);
        return;
    }
    emit_expr(c, e, depth);
    emit_line(c, depth, "(call $lua_truthy)\n");
}

/* Concatenate `parts[0..k)` (already in source order): up to four at once
 * ($lua_concat / 3 / 4), a longer chain as its first three plus the rest. */
static void emit_concat_parts(CG *c, const Expr *const *parts, int k, int depth) {
    emit_line(c, depth, k == 2 ? "(call $lua_concat\n" : k == 3 ? "(call $lua_concat3\n"
                                                                : "(call $lua_concat4\n");
    int direct = k <= 4 ? k : 3;
    for (int i = 0; i < direct; i++) emit_expr(c, parts[i], depth + 1);
    if (k > 4) emit_concat_parts(c, parts + 3, k - 3, depth + 1);
    emit_line(c, depth, ")\n");
}

static void emit_binop(CG *c, const Expr *e, int depth) {
    BinOp op = e->as.binop.op;
    if (op == BIN_AND || op == BIN_OR) {
        int label = c->next_label++;
        emit_linef(c, depth, "(block $sc_%d (result anyref)\n", label);

        emit_expr(c, e->as.binop.lhs, depth + 1);
        emit_line(c, depth + 1, "local.set $tmp_any\n");
        emit_line(c, depth + 1, "(call $lua_truthy (local.get $tmp_any))\n");
        emit_line(c, depth + 1, "(if (then\n");
        if (op == BIN_AND) {
            emit_expr(c, e->as.binop.rhs, depth + 2);
            emit_linef(c, depth + 2, "br $sc_%d\n", label);
            emit_line(c, depth + 1, "))\n");
            emit_line(c, depth + 1, "local.get $tmp_any\n");
        } else {
            emit_line(c, depth + 2, "local.get $tmp_any\n");
            emit_linef(c, depth + 2, "br $sc_%d\n", label);
            emit_line(c, depth + 1, "))\n");
            emit_expr(c, e->as.binop.rhs, depth + 1);
        }
        emit_line(c, depth, ")\n");
        return;
    }
    if (expr_involves_maybe(c, e)) {
        if (is_cmp_op(op)) {
            emit_line(c, depth, "(select (result anyref)\n");
            emit_line(c, depth + 1, "(global.get $g_true)\n");
            emit_line(c, depth + 1, "(global.get $g_false)\n");
            emit_maybe_cmp_block(c, e, depth + 1);
            emit_line(c, depth, ")\n");
        } else {
            emit_maybe_boxed(c, e, depth);
        }
        return;
    }
    CmpKind ck = cmp_numeric_kind(c, e);
    if (ck) {
        /* Value context: materialize the i32 compare as a Lua boolean. */
        emit_line(c, depth, "(select (result anyref)\n");
        emit_line(c, depth + 1, "(global.get $g_true)\n");
        emit_line(c, depth + 1, "(global.get $g_false)\n");
        emit_cmp_i32(c, e, depth + 1, ck);
        emit_line(c, depth, ")\n");
        return;
    }
    if (op == BIN_CONCAT) {
        /* `a .. b .. c ...` parses right-nested; flatten the unparenthesized
         * right spine so the whole chain is built in one allocation. (A
         * parenthesized `(a .. b) .. c` keeps its grouping: with __concat
         * the order of the pairwise calls is observable.) */
        const Expr *parts[64];
        int k = 0;
        const Expr *cur = e;
        while (cur->kind == EXPR_BINOP && cur->as.binop.op == BIN_CONCAT && (cur == e || !cur->paren) &&
               k < 63) {
            parts[k++] = cur->as.binop.lhs;
            cur = cur->as.binop.rhs;
        }
        parts[k++] = cur;
        emit_concat_parts(c, parts, k, depth);
        return;
    }
    const char *helper = binop_helper(op);
    if (!helper) {
        cg_error(c, "internal: unhandled binary operator");
        return;
    }
    emit_expr(c, e->as.binop.lhs, depth);
    emit_expr(c, e->as.binop.rhs, depth);
    emit_linef(c, depth, "(call %s)\n", helper);
}

static void emit_unop(CG *c, const Expr *e, int depth) {
    if (e->as.unop.op == UN_NEG && expr_involves_maybe(c, e)) {
        emit_maybe_boxed(c, e, depth);
        return;
    }
    emit_expr(c, e->as.unop.operand, depth);
    emit_indent(c, depth);
    switch (e->as.unop.op) {
    case UN_NEG: wat_append(c->w, "(call $lua_neg)\n"); break;
    case UN_NOT: wat_append(c->w, "(call $lua_not)\n"); break;
    case UN_LEN: wat_append(c->w, "(call $lua_len)\n"); break;
    case UN_BNOT: wat_append(c->w, "(call $lua_bnot)\n"); break;
    }
}

/* An expression whose value in a multi-value position is a full $ArgArr
 * (call/method-call/vararg) rather than a single anyref. */
static int is_multival_tail(const Expr *e) {
    if (e->paren) return 0; /* `(f())` is adjusted to a single value */
    return e->kind == EXPR_CALL ||
           e->kind == EXPR_METHOD_CALL ||
           e->kind == EXPR_VARARG;
}

/* Emit (ref $ArgArr) for a multi-value expression (last-in-list context). */
static void emit_call_array(CG *c, const Expr *e, int depth);
static void emit_multival_array(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_VARARG) {
        emit_line(c, depth, "(local.get $varargs)\n");
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
            if (K && K->func_idx != c->cur_func_idx) K = NULL; /* self-recursion only */
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
        if (pt == NT_INT) emit_int_expr(c, a, depth);
        else if (pt == NT_FLOAT) emit_num_as_f64(c, a, depth);
        else emit_expr(c, a, depth);
    }
}

/* Emit a direct call to K's single-value entry $user_K_da1 (closure + typed
 * args). The result lands as the entry's declared type: raw i64/f64 when K has a
 * numeric ret_ty, otherwise a single anyref. Callers ensure args are typed-ok. */
static void emit_typed_direct_call1(CG *c, const Expr *e, const LuaFunc *K, int depth) {
    const FuncSig *sg = target_sig(c, K);
    emit_linef(c, depth, "(call $user_%d_da1\n", K->func_idx);
    emit_line(c, depth + 1, "(ref.cast (ref $LuaClosure)\n");
    emit_expr(c, e->as.call.callee, depth + 2);
    emit_line(c, depth + 1, ")\n");
    emit_typed_args(c, e, sg, depth + 1);
    emit_line(c, depth, ")\n");
}

/* Single-result calls with at most this many arguments (a method call's
 * receiver included) use the closure's $fast entry ($LuaFn1). */
#define FAST_MAX_ARGS 4

/* Whether `fn` gets a $user_N_f body: the specializer is on and its named
 * parameters fit the fast entry's argument registers. Other closures use
 * $fast_adapter. */
static int fn_has_fast_entry(const CG *c, const LuaFunc *fn) {
    return c->opt_int && fn->n_params <= FAST_MAX_ARGS;
}

/* A call's or method call's own argument list (a method call's receiver is
 * not part of it). */
static void call_arg_list(const Expr *e, Expr *const **args, size_t *n) {
    if (e->kind == EXPR_METHOD_CALL) {
        *args = e->as.method_call.args;
        *n = e->as.method_call.nargs;
    } else {
        *args = e->as.call.args;
        *n = e->as.call.nargs;
    }
}

/* The number of fast-entry arguments of a call or method call (the receiver
 * counts), or -1 when it can't use the fast entry: too many, or a trailing
 * multi-value argument whose length is only known at run time. */
static int fast_call_nargs(const CG *c, const Expr *e) {
    if (!c->opt_int || (e->kind != EXPR_CALL && e->kind != EXPR_METHOD_CALL)) return -1;
    Expr *const *args;
    size_t na;
    call_arg_list(e, &args, &na);
    size_t n = na + (e->kind == EXPR_METHOD_CALL);
    if (n > FAST_MAX_ARGS) return -1;
    if (na > 0 && is_multival_tail(args[na - 1])) return -1;
    return (int)n;
}

/* Build a (ref $ArgArr) from a sequence of argument expressions, splicing
 * the trailing expression's full multi-value result if it is a call or `...`. */
static void emit_args_array(CG *c, Expr **args, size_t nargs, int depth) {
    if (nargs == 0) {
        emit_line(c, depth, "(global.get $g_empty_args)\n");
        return;
    }
    int last_mv = is_multival_tail(args[nargs - 1]);
    if (!last_mv) {
        emit_linef(c, depth, "(array.new_fixed $ArgArr %zu\n", nargs);
        for (size_t i = 0; i < nargs; i++) emit_expr(c, args[i], depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    size_t singles = nargs - 1;
    emit_line(c, depth, "(call $merge_args\n");
    if (singles == 0) {
        emit_line(c, depth + 1, "(global.get $g_empty_args)\n");
    } else {
        emit_linef(c, depth + 1, "(array.new_fixed $ArgArr %zu\n", singles);
        for (size_t i = 0; i < singles; i++) emit_expr(c, args[i], depth + 2);
        emit_line(c, depth + 1, ")\n");
    }
    emit_multival_array(c, args[nargs - 1], depth + 1);
    emit_line(c, depth, ")\n");
}

/* A method call `obj:m(...)` evaluates obj once, into $tmp_any, where the
 * method lookup and the argument list read it. Both read it before any
 * argument is evaluated, so an argument that is itself a method call may
 * reuse $tmp_any. */
static void emit_park_receiver(CG *c, const Expr *e, int depth) {
    emit_line(c, depth, "(local.set $tmp_any\n");
    emit_expr(c, e->as.method_call.recv, depth + 1);
    emit_line(c, depth, ")\n");
}

/* Look up `obj:m` via $lua_index_sk (constant string key; routes strings
 * through the string library). The receiver must already be parked in
 * $tmp_any. Emits, at `depth`:
 *   (call $lua_index_sk (local.get $tmp_any) <hoisted method name> (i32.const line))
 * Shared by the value and tail-call method forms. */
static void emit_method_lookup(CG *c, const char *method, size_t method_len, int line,
                               int depth) {
    emit_indent(c, depth);
    /* $lua_index_sk reads the key's precomputed hash, so it is only for hoisted
     * constants; a name too long to hoist takes the generic lookup. With the
     * specializer on, a hoisted name gets a method inline cache. */
    int mic = c->opt_int && method_len <= KSTR_MAX ? c->n_mics++ : -1;
    wat_append(c->w, mic >= 0                 ? "(call $lua_method_ic\n"
                     : method_len <= KSTR_MAX ? "(call $lua_index_sk\n"
                                              : "(call $lua_index\n");
    emit_line(c, depth + 1, "(local.get $tmp_any)\n");
    emit_string_literal(c, method, method_len, depth + 1);
    emit_linef(c, depth + 1, "(i32.const %d)\n", line);
    if (mic >= 0) {
        emit_linef(c, depth + 1, "(global.get $mic_%d)\n", mic);
    }
    emit_line(c, depth, ")\n");
}

/* The value a call calls: a call's callee expression, or a method call's
 * method looked up on the parked receiver. */
static void emit_callee(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL)
        emit_method_lookup(c, e->as.method_call.method, e->as.method_call.method_len, e->line, depth);
    else emit_expr(c, e->as.call.callee, depth);
}

/* Emit the method-call argument array [recv] ++ method-args, at `depth`:
 *   (call $merge_args (array.new_fixed $ArgArr 1 (local.get $tmp_any)) <args>)
 * The receiver must already be parked in $tmp_any. Shared by the value and
 * tail-call method forms. */
static void emit_method_args_array(CG *c, const Expr *e, int depth) {
    size_t mna = e->as.method_call.nargs;
    int has_mv = mna > 0 && is_multival_tail(e->as.method_call.args[mna - 1]);
    if (!has_mv) {
        /* Fixed arity: build [recv, args...] in one array.new_fixed. The
         * receiver is read from $tmp_any first (operand order), so an argument
         * that is itself a method call may reuse $tmp_any safely. */
        emit_linef(c, depth, "(array.new_fixed $ArgArr %zu\n", mna + 1);
        emit_line(c, depth + 1, "(local.get $tmp_any)\n");
        for (size_t i = 0; i < mna; i++) emit_expr(c, e->as.method_call.args[i], depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    emit_line(c, depth, "(call $merge_args\n");
    emit_line(c, depth + 1, "(array.new_fixed $ArgArr 1 (local.get $tmp_any))\n");
    emit_args_array(c, e->as.method_call.args, mna, depth + 1);
    emit_line(c, depth, ")\n");
}

/* A call's arguments as an $ArgArr (a method call's with its receiver first). */
static void emit_call_args_array(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL) emit_method_args_array(c, e, depth);
    else emit_args_array(c, e->as.call.args, e->as.call.nargs, depth);
}

/* A call returning (ref $ArgArr) — the full multi-value result. */
static void emit_call_array(CG *c, const Expr *e, int depth) {
    const LuaFunc *dt = direct_call_target(c, e);
    if (dt && direct_args_typed_ok(c, e, dt)) {
        /* Direct-args call: pass the closure + (typed) args to $user_N_da,
         * no $ArgArr allocation. Returns the result array like $lua_call_any.
         * (Frame push/pop is skipped — a known function needs no __call walk;
         * error positions inside it fall back to the caller's frame, matching
         * the project's "error position not tracked" stance.) */
        emit_linef(c, depth, "(call $user_%d_da\n", dt->func_idx);
        emit_line(c, depth + 1, "(ref.cast (ref $LuaClosure)\n");
        emit_expr(c, e->as.call.callee, depth + 2);
        emit_line(c, depth + 1, ")\n");
        emit_typed_args(c, e, target_sig(c, dt), depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    if (e->kind == EXPR_METHOD_CALL) emit_park_receiver(c, e, depth);
    emit_line(c, depth, "(call $lua_call_any\n");
    emit_callee(c, e, depth + 1);
    emit_call_args_array(c, e, depth + 1);
    emit_linef(c, depth + 1, "(i32.const %d)\n", e->line);
    emit_line(c, depth, ")\n");
}

/* A single-result call through $lua_call1 (the callee's $fast entry): the
 * callee, then the arguments in order — a method call's receiver first —
 * nil-padded to four, plus the count. Callers check fast_call_nargs first. */
static void emit_fast_call(CG *c, const Expr *e, int depth) {
    int n = fast_call_nargs(c, e);
    Expr *const *args;
    size_t na;
    call_arg_list(e, &args, &na);
    if (e->kind == EXPR_METHOD_CALL) emit_park_receiver(c, e, depth);
    emit_line(c, depth, "(call $lua_call1\n");
    emit_callee(c, e, depth + 1);
    if (e->kind == EXPR_METHOD_CALL) emit_line(c, depth + 1, "(local.get $tmp_any)\n");
    for (size_t i = 0; i < na; i++) emit_expr(c, args[i], depth + 1);
    for (int i = n; i < FAST_MAX_ARGS; i++) emit_line(c, depth + 1, "(ref.null any)\n");
    emit_linef(c, depth + 1, "(i32.const %d) (i32.const %d)\n", n, e->line);
    emit_line(c, depth, ")\n");
}

/* A call in single-value context: the direct single-result entry, the fast
 * entry, or the full call with its first result taken. */
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
    if (fast_call_nargs(c, e) >= 0) {
        emit_fast_call(c, e, depth);
        return;
    }
    emit_line(c, depth, "(call $args_first\n");
    emit_call_array(c, e, depth + 1);
    emit_line(c, depth, ")\n");
}

/* ----- tail calls -----
 * `return f(args)` / `return obj:m(args)` lowers to a return_call_ref, so
 * deep recursion doesn't grow the wasm call stack. */

/* Evaluate a tail call's callee into $tmp_callee — not $tmp_any, which a
 * method call among the arguments reuses for its receiver while the
 * arguments are evaluated. */
static void emit_tail_callee(CG *c, const Expr *e, int depth) {
    if (e->kind == EXPR_METHOD_CALL) emit_park_receiver(c, e, depth);
    emit_line(c, depth, "(local.set $tmp_callee\n");
    emit_callee(c, e, depth + 1);
    emit_line(c, depth, ")\n");
}

/* The end of a tail call whose callee is in $tmp_callee. A closure takes over
 * the caller's frame — its line becomes this call site's, so error() and
 * tracebacks see it — and is entered with `entry_call`, a return_call_ref.
 * Anything else (a __call table, a non-callable) takes `slow_call`, an
 * ordinary call that walks __call or raises: losing TCO for a metamethod hop
 * is fine. */
static void emit_tail_dispatch(CG *c, int line, const char *entry_call, const char *slow_call, int depth) {
    emit_line(c, depth, "(if (ref.test (ref $LuaClosure) (local.get $tmp_callee))\n");
    emit_line(c, depth + 1, "(then\n");
    emit_line(c, depth + 2, "(local.set $tmp_clo (ref.cast (ref $LuaClosure) (local.get $tmp_callee)))\n");
    emit_linef(c, depth + 2,
               "(call $replace_top_call_frame (i32.const %d) "
               "(struct.get $LuaClosure $weight (ref.as_non_null (local.get $tmp_clo))))\n",
               line);
    emit_linef(c, depth + 2, "%s))\n", entry_call);
    emit_linef(c, depth, "(return %s)\n", slow_call);
}

/* A tail call through the callee's $code: the arguments as an array. */
static void emit_tail_call(CG *c, const Expr *e, int depth) {
    emit_tail_callee(c, e, depth);
    emit_line(c, depth, "(local.set $tmp_args\n");
    emit_call_args_array(c, e, depth + 1);
    emit_line(c, depth, ")\n");
    char slow[160];
    snprintf(slow, sizeof slow,
             "(call $lua_call_any (local.get $tmp_callee) (ref.as_non_null (local.get $tmp_args)) (i32.const %d))",
             e->line);
    emit_tail_dispatch(c, e->line,
                       "(return_call_ref $LuaFn (ref.as_non_null (local.get $tmp_clo)) "
                       "(ref.as_non_null (local.get $tmp_args)) "
                       "(struct.get $LuaClosure $code (ref.as_non_null (local.get $tmp_clo))))",
                       slow, depth);
}

/* A tail call inside a $user_N_f body that fits the fast entry: through the
 * callee's $fast, the arguments evaluated in order into $ta0..$ta3 (a method
 * call's receiver first). */
static void emit_fast_tail_call(CG *c, const Expr *e, int depth) {
    int n = fast_call_nargs(c, e), k = 0;
    Expr *const *args;
    size_t na;
    call_arg_list(e, &args, &na);
    emit_tail_callee(c, e, depth);
    if (e->kind == EXPR_METHOD_CALL) emit_line(c, depth, "(local.set $ta0 (local.get $tmp_any))\n"), k = 1;
    for (size_t i = 0; i < na; i++, k++) {
        emit_linef(c, depth, "(local.set $ta%d\n", k);
        emit_expr(c, args[i], depth + 1);
        emit_line(c, depth, ")\n");
    }
    char regs[160], entry[384], slow[256];
    int off = 0;
    for (int i = 0; i < FAST_MAX_ARGS; i++)
        off += snprintf(regs + off, sizeof regs - (size_t)off, i < n ? " (local.get $ta%d)" : " (ref.null any)", i);
    snprintf(entry, sizeof entry,
             "(return_call_ref $LuaFn1 (ref.as_non_null (local.get $tmp_clo))%s (i32.const %d) "
             "(struct.get $LuaClosure $fast (ref.as_non_null (local.get $tmp_clo))))",
             regs, n);
    snprintf(slow, sizeof slow, "(call $lua_call1 (local.get $tmp_callee)%s (i32.const %d) (i32.const %d))", regs, n,
             e->line);
    emit_tail_dispatch(c, e->line, entry, slow, depth);
}

/* ----- function expression: build a closure -----
 * The upvalue array collects the parent's boxes per the function's
 * upvalue table.
 */
static int fn_frame_weight(CG *c, const LuaFunc *fn);
static void emit_function_expr(CG *c, const LuaFunc *fn, int depth) {
    emit_line(c, depth, "(struct.new $LuaClosure\n");
    emit_linef(c, depth + 1, "(ref.func $user_%d)\n", fn->func_idx);
    if (fn->n_upvalues == 0) {
        emit_line(c, depth + 1, "(global.get $g_empty_upvals)\n");
    } else {
        emit_linef(c, depth + 1, "(array.new_fixed $UpvalArr %d\n", fn->n_upvalues);
        for (int i = 0; i < fn->n_upvalues; i++) {
            UpvalueRef *u = &fn->upvalues[i];
            VarKind k = (u->src == UPVAL_FROM_LOCAL) ? VAR_LOCAL : VAR_UPVAL;
            emit_box_ref(c, k, u->idx, depth + 2);
        }
        emit_line(c, depth + 1, ")\n");
    }
    emit_linef(c, depth + 1, "(i32.const %d)\n", fn_frame_weight(c, fn));
    emit_indent(c, depth + 1);
    if (fn_has_fast_entry(c, fn)) wat_appendf(c->w, "(ref.func $user_%d_f)\n", fn->func_idx);
    else wat_append(c->w, "(ref.func $fast_adapter)\n");
    emit_line(c, depth, ")\n");
}

/* ----- table operations ----- */
static void emit_index_expr(CG *c, const Expr *e, int depth) {
    /* `t[k]`. Use the runtime $lua_index helper instead of an inline
     * (ref.cast (ref $LuaTable) …) so that strings transparently route
     * through the string library and other-typed receivers throw a
     * Lua-shaped error with a source line. For an int-typed key, the
     * $lua_index_ik fast path takes the raw i64 (no make_int / $as_arr_key)
     * and hits the array part directly. */
    if (e->as.index.key->kind == EXPR_STRING && e->as.index.key->as.s.len <= KSTR_MAX) {
        /* `t.name` / `t["lit"]`: the hoisted key global goes straight to the
         * hash part (strings never live in the array part), through the
         * site's inline cache when the specializer is on. */
        char icb[48];
        const char *ic = ic_new(c, icb, sizeof icb);
        emit_line(c, depth, ic ? "(call $lua_index_ic\n" : "(call $lua_index_sk\n");
        emit_expr(c, e->as.index.table, depth + 1);
        emit_string_literal(c, e->as.index.key->as.s.bytes, e->as.index.key->as.s.len, depth + 1);
        emit_linef(c, depth + 1, "(i32.const %d)%s%s\n", e->line, ic ? " " : "", ic ? ic : "");
        emit_line(c, depth, ")\n");
        return;
    }
    if (e->as.index.key->kind == EXPR_VAR && e->as.index.key->as.var.kind == VAR_LOCAL &&
        slot_is_maybe(c, e->as.index.key->as.var.idx)) {
        /* Maybe-typed key: the cell goes over unboxed; an int takes the
         * array fast path, anything else boxes on the slow path. */
        MCell k = mcell_slot(e->as.index.key->as.var.idx);
        emit_line(c, depth, "(call $lua_index_mk\n");
        emit_expr(c, e->as.index.table, depth + 1);
        emit_linef(c, depth + 1, "%s %s %s %s (i32.const %d)\n", k.t, k.i, k.f, k.b, e->line);
        emit_line(c, depth, ")\n");
        return;
    }
    if (c->opt_int && expr_is_int(c, e->as.index.key)) {
        emit_line(c, depth, "(call $lua_index_ik\n");
        emit_expr(c, e->as.index.table, depth + 1);
        emit_int_expr(c, e->as.index.key, depth + 1);
        emit_linef(c, depth + 1, "(i32.const %d)\n", e->line);
        emit_line(c, depth, ")\n");
        return;
    }
    emit_line(c, depth, "(call $lua_index\n");
    emit_expr(c, e->as.index.table, depth + 1);
    emit_expr(c, e->as.index.key, depth + 1);
    emit_linef(c, depth + 1, "(i32.const %d)\n", e->line);
    emit_line(c, depth, ")\n");
}

/* Largest record a constructor builds on a cached shape; matches the
 * runtime's $shape_share_max (a table with more keys is a dictionary). */
#define CTOR_SHAPE_MAX 32

/* The number of `name = v` fields of a constructor that can be built on a
 * cached shape: every non-positional key a hoistable constant string, all
 * distinct, at most CTOR_SHAPE_MAX of them. 0 when there are none or the
 * constructor doesn't qualify (computed keys keep the incremental path). */
static int ctor_shape_fields(const CG *c, const Expr *e) {
    if (!c->opt_int) return 0;
    int n = e->as.table_ctor.n_entries, k = 0;
    for (int i = 0; i < n; i++) {
        const TableEntry *ent = &e->as.table_ctor.entries[i];
        if (ent->kind == TENT_POSITIONAL) continue;
        if (ent->key->kind != EXPR_STRING || ent->key->as.s.len > KSTR_MAX) return 0;
        for (int j = 0; j < i; j++) {
            const TableEntry *o = &e->as.table_ctor.entries[j];
            if (o->kind != TENT_POSITIONAL && o->key->as.s.len == ent->key->as.s.len &&
                memcmp(o->key->as.s.bytes, ent->key->as.s.bytes, ent->key->as.s.len) == 0)
                return 0;
        }
        k++;
    }
    return k <= CTOR_SHAPE_MAX ? k : 0;
}

static void emit_table_ctor(CG *c, const Expr *e, int depth) {
    int n = e->as.table_ctor.n_entries;
    /* Wrap in a block so the constructor appears as a single folded
     * expression from outside (works inside array.new_fixed arg lists,
     * function calls, etc.) but uses stack-form internally to keep the
     * in-progress table on the operand stack across entries. */
    emit_line(c, depth, "(block (result anyref)\n");
    int nshape = ctor_shape_fields(c, e);
    if (nshape > 0) {
        /* Its fields' final layout is known: start from the site's cached
         * shape (built on first use) and fill values in by position. */
        int site = c->n_ctor_shapes++;
        emit_linef(c, depth + 1, "(if (ref.is_null (global.get $cshape_%d))\n", site);
        emit_linef(c, depth + 2, "(then (global.set $cshape_%d (call $shape_for_keys (array.new_fixed $TArr %d", site,
                   nshape);
        for (int i = 0; i < n; i++) {
            const TableEntry *ent = &e->as.table_ctor.entries[i];
            if (ent->kind == TENT_POSITIONAL) continue;
            char eb[160];
            wat_appendf(c->w, " %s", kstr_expr(c, ent->key->as.s.bytes, ent->key->as.s.len, eb, sizeof eb));
        }
        wat_append(c->w, ")))))\n");
        emit_linef(c, depth + 1, "(call $tab_new_shaped (ref.as_non_null (global.get $cshape_%d)))\n", site);
    } else {
        emit_line(c, depth + 1, "(call $tab_new)\n");
    }
    int field_pos = 0;
    int pos_idx = 1;
    /* If the final entry is positional AND a multi-value tail (call/vararg),
     * we splice all of its values rather than just taking the first. */
    int splice_last = (n > 0 &&
                       e->as.table_ctor.entries[n - 1].kind == TENT_POSITIONAL &&
                       is_multival_tail(e->as.table_ctor.entries[n - 1].value));
    int last_normal = splice_last ? n - 1 : n;
    for (int i = 0; i < last_normal; i++) {
        TableEntry *ent = &e->as.table_ctor.entries[i];
        emit_line(c, depth + 1, "local.tee $tmp_tab\n");
        emit_line(c, depth + 1, "(ref.as_non_null (local.get $tmp_tab))\n");
        if (ent->kind == TENT_POSITIONAL) {
            /* Raw integer key: straight to the array part, no key boxing. */
            emit_linef(c, depth + 1, "(i64.const %d)\n", pos_idx++);
            emit_expr(c, ent->value, depth + 1);
            emit_line(c, depth + 1, "call $tab_set_ik\n");
            continue;
        }
        if (nshape > 0) {
            /* A field of a shaped constructor: its value goes to its position. */
            int vfloat = expr_is_float(c, ent->value);
            emit_linef(c, depth + 1, "(i32.const %d)\n", field_pos++);
            if (vfloat) emit_float_expr(c, ent->value, depth + 1);
            else emit_expr(c, ent->value, depth + 1);
            emit_line(c, depth + 1, vfloat ? "call $tab_put_pos_f\n" : "call $tab_put_pos\n");
            continue;
        }
        if (ent->key->kind == EXPR_STRING && ent->key->as.s.len <= KSTR_MAX) {
            /* `{name = v}`: hoisted key global + its precomputed hash, straight
             * into the hash part (a fresh table has no metatable). A provably
             * float value goes into the unboxed float storage. */
            char eb[160];
            int vfloat = c->opt_int && expr_is_float(c, ent->value);
            emit_linef(c, depth + 1, "%s\n",
                       kstr_expr(c, ent->key->as.s.bytes, ent->key->as.s.len, eb, sizeof eb));
            emit_linef(c, depth + 1, "(i32.const %d)\n",
                       (int)kstr_hash(ent->key->as.s.bytes, ent->key->as.s.len));
            if (vfloat) emit_float_expr(c, ent->value, depth + 1);
            else emit_expr(c, ent->value, depth + 1);
            emit_line(c, depth + 1, vfloat ? "call $tab_set_f_hash_str\n" : "call $tab_set_hash_str\n");
            continue;
        }
        emit_expr(c, ent->key, depth + 1);
        emit_expr(c, ent->value, depth + 1);
        emit_line(c, depth + 1, "call $tab_set\n");
    }
    if (splice_last) {
        /* (call $tab_append_args (local.tee $tmp_tab) (i32.const pos_idx) <args>) */
        emit_line(c, depth + 1, "local.tee $tmp_tab\n");
        emit_line(c, depth + 1, "(call $tab_append_args\n");
        emit_line(c, depth + 2, "(ref.as_non_null (local.get $tmp_tab))\n");
        emit_linef(c, depth + 2, "(i32.const %d)\n", pos_idx);
        emit_multival_array(c, e->as.table_ctor.entries[n - 1].value, depth + 2);
        emit_line(c, depth + 1, ")\n");
    }
    emit_line(c, depth, ")\n");
}

/* ----- statement traversal -----
 * Analyses look at one function body at a time: every statement, those in
 * nested blocks included, but not nested function literals — each function
 * is analysed on its own. */
typedef void (*BlockVisit)(const Block *b, void *ctx);
typedef void (*StmtVisit)(const Stmt *s, void *ctx);
typedef void (*ExprVisit)(const Expr *e, void *ctx);

/* Call fn on each block nested directly in s, in source order: an `if`'s arm
 * bodies then its else body, or the body of a loop or `do`. */
static void for_each_nested_block(const Stmt *s, BlockVisit fn, void *ctx) {
    switch (s->kind) {
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++) fn(&s->as.if_stmt.arms[a].body, ctx);
        if (s->as.if_stmt.has_else) fn(&s->as.if_stmt.else_body, ctx);
        break;
    case STMT_WHILE: fn(&s->as.while_stmt.body, ctx); break;
    case STMT_DO: fn(&s->as.do_stmt.body, ctx); break;
    case STMT_REPEAT: fn(&s->as.repeat.body, ctx); break;
    case STMT_FOR_NUM: fn(&s->as.for_num.body, ctx); break;
    case STMT_FOR_GEN: fn(&s->as.for_gen.body, ctx); break;
    default: break;
    }
}

typedef struct {
    StmtVisit fn;
    void *ctx;
} StmtWalk;
static void walk_stmts_in(const Block *b, void *walk) {
    const StmtWalk *w = walk;
    for (size_t i = 0; i < b->count; i++) {
        w->fn(b->items[i], w->ctx);
        for_each_nested_block(b->items[i], walk_stmts_in, walk);
    }
}

/* Call fn on every statement of b, nested ones included, in source order:
 * each statement before those nested in it. */
static void walk_stmts(const Block *b, StmtVisit fn, void *ctx) {
    StmtWalk w = {fn, ctx};
    walk_stmts_in(b, &w);
}

/* Call fn on each expression s evaluates itself — not those of its nested
 * blocks: values, conditions, index targets, loop bounds, iterators. */
static void for_each_own_expr(const Stmt *s, ExprVisit fn, void *ctx) {
    switch (s->kind) {
    case STMT_LOCAL:
        for (int i = 0; i < s->as.local.n_values; i++) fn(s->as.local.values[i], ctx);
        break;
    case STMT_ASSIGN:
        for (int i = 0; i < s->as.assign.n_targets; i++)
            if (s->as.assign.targets[i].kind == TGT_INDEX) {
                fn(s->as.assign.targets[i].as.index.table, ctx);
                fn(s->as.assign.targets[i].as.index.key, ctx);
            }
        for (int i = 0; i < s->as.assign.n_values; i++) fn(s->as.assign.values[i], ctx);
        break;
    case STMT_EXPR: fn(s->as.expr_stmt.expr, ctx); break;
    case STMT_IF:
        for (size_t a = 0; a < s->as.if_stmt.narms; a++) fn(s->as.if_stmt.arms[a].cond, ctx);
        break;
    case STMT_WHILE: fn(s->as.while_stmt.cond, ctx); break;
    case STMT_REPEAT: fn(s->as.repeat.cond, ctx); break;
    case STMT_RETURN:
        for (int i = 0; i < s->as.return_stmt.n_values; i++) fn(s->as.return_stmt.values[i], ctx);
        break;
    case STMT_FOR_NUM:
        fn(s->as.for_num.start, ctx);
        fn(s->as.for_num.stop, ctx);
        if (s->as.for_num.step) fn(s->as.for_num.step, ctx);
        break;
    case STMT_FOR_GEN:
        for (int i = 0; i < s->as.for_gen.n_exprs; i++) fn(s->as.for_gen.exprs[i], ctx);
        break;
    case STMT_GLOBAL:
        for (int i = 0; i < s->as.global_decl.n_values; i++) fn(s->as.global_decl.values[i], ctx);
        break;
    default: break;
    }
}

typedef struct {
    ExprVisit fn;
    void *ctx;
} ExprWalk;
static void walk_own_exprs(const Stmt *s, void *walk) {
    const ExprWalk *w = walk;
    for_each_own_expr(s, w->fn, w->ctx);
}

/* Call fn on every expression the statements of b evaluate, nested blocks
 * included. fn sees the roots; it recurses into sub-expressions itself. */
static void walk_block_exprs(const Block *b, ExprVisit fn, void *ctx) {
    ExprWalk w = {fn, ctx};
    walk_stmts(b, walk_own_exprs, &w);
}

/* ----- integer specialization (opt >= 1) ----- */

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
        case BIN_ADD:
        case BIN_SUB:
        case BIN_MUL:
        case BIN_FDIV:
        case BIN_MOD:
        case BIN_BAND:
        case BIN_BOR:
        case BIN_BXOR:
            return expr_is_int(c, e->as.binop.lhs) && expr_is_int(c, e->as.binop.rhs);
        default: return 0;
        }
    case EXPR_UNOP:
        return (e->as.unop.op == UN_NEG || e->as.unop.op == UN_BNOT) && expr_is_int(c, e->as.unop.operand);
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
        emit_linef(c, depth, "(i64.const %lld)\n", (long long)e->as.i_val);
        return;
    case EXPR_VAR:
        emit_linef(c, depth, "(local.get $L%d)\n", e->as.var.idx);
        return;
    case EXPR_UNOP:
        if (e->as.unop.op == UN_NEG) {
            emit_line(c, depth, "(i64.sub (i64.const 0)\n");
            emit_int_expr(c, e->as.unop.operand, depth + 1);
            emit_line(c, depth, ")\n");
        } else { /* UN_BNOT */
            emit_line(c, depth, "(i64.xor (i64.const -1)\n");
            emit_int_expr(c, e->as.unop.operand, depth + 1);
            emit_line(c, depth, ")\n");
        }
        return;
    case EXPR_BINOP: {
        const char *op = NULL, *fn = NULL;
        switch (e->as.binop.op) {
        case BIN_ADD: op = "i64.add"; break;
        case BIN_SUB: op = "i64.sub"; break;
        case BIN_MUL: op = "i64.mul"; break;
        case BIN_BAND: op = "i64.and"; break;
        case BIN_BOR: op = "i64.or"; break;
        case BIN_BXOR: op = "i64.xor"; break;
        case BIN_FDIV: fn = "$idiv_floor"; break;
        case BIN_MOD: fn = "$imod_floor"; break;
        default: break;
        }
        emit_indent(c, depth);
        if (fn) wat_appendf(c->w, "(call %s\n", fn);
        else wat_appendf(c->w, "(%s\n", op);
        emit_int_expr(c, e->as.binop.lhs, depth + 1);
        emit_int_expr(c, e->as.binop.rhs, depth + 1);
        emit_line(c, depth, ")\n");
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
        case BIN_DIV: return ln && rn; /* always float */
        case BIN_ADD:
        case BIN_SUB:
        case BIN_MUL:
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
    if (expr_is_float(c, e)) {
        emit_float_expr(c, e, depth);
        return;
    }
    /* must be integer-typed (the only other case expr_is_float admits) */
    emit_line(c, depth, "(f64.convert_i64_s\n");
    emit_int_expr(c, e, depth + 1);
    emit_line(c, depth, ")\n");
}

/* Emit `e` (which must satisfy expr_is_float) as a raw f64 on the wasm stack. */
static void emit_float_expr(CG *c, const Expr *e, int depth) {
    if (!c->ok) return;
    switch (e->kind) {
    case EXPR_FLOAT:
        emit_linef(c, depth, "(f64.const %.17g)\n", e->as.f_val);
        return;
    case EXPR_VAR:
        emit_linef(c, depth, "(local.get $L%d)\n", e->as.var.idx);
        return;
    case EXPR_UNOP: /* UN_NEG */
        emit_line(c, depth, "(f64.neg\n");
        emit_num_as_f64(c, e->as.unop.operand, depth + 1);
        emit_line(c, depth, ")\n");
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
        emit_linef(c, depth, "(%s\n", op);
        emit_num_as_f64(c, e->as.binop.lhs, depth + 1);
        emit_num_as_f64(c, e->as.binop.rhs, depth + 1);
        emit_line(c, depth, ")\n");
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

/* One run of a slot-typing analysis: out[] holds the slots still believed
 * to have the type; a kill rule that finds a store contradicting it drops
 * the slot, and the analysis reruns until nothing changes. */
typedef struct {
    CG *c;
    unsigned char *out;
    int changed;
    NumTy ty; /* the int / float analysis: NT_INT or NT_FLOAT */
} SlotPass;

static void slot_kill(SlotPass *p, int slot) {
    if (slot >= 0 && slot < p->c->cur_n_locals && p->out[slot]) {
        p->out[slot] = 0;
        p->changed = 1;
    }
}

/* Lua 5.4+: integer init and step make a numeric for an integer loop,
 * whatever the limit is ($for_limit settles a non-integer limit at loop
 * entry). */
static int int_for_loop(CG *c, const Stmt *s) {
    const Expr *st = s->as.for_num.step;
    return expr_is_int(c, s->as.for_num.start) && (st == NULL || expr_is_int(c, st));
}

static int expr_has_ty(CG *c, const Expr *e, NumTy ty) {
    return ty == NT_INT ? expr_is_int(c, e) : expr_is_float(c, e);
}

/* Kill rules of the int and float analyses: a slot keeps the type only if
 * every store to it is a single expression of that type (a multi-value store
 * writes anyref). Never typed: a <close> variable, whose value flows into the
 * to-be-closed machinery ($tbc_push/$close_upto) as an anyref; generic-for
 * variables; local functions; and numeric-for control variables, except the
 * int one of an integer loop (there is no f64 for-loop). */
static void typed_kill_stmt(const Stmt *s, void *ctx) {
    SlotPass *p = ctx;
    CG *c = p->c;
    switch (s->kind) {
    case STMT_LOCAL: {
        int nn = s->as.local.n_names, nv = s->as.local.n_values;
        for (int j = 0; j < nn; j++) {
            int is_close = s->as.local.attribs && s->as.local.attribs[j] == 2;
            if (!is_close && nv == nn && expr_has_ty(c, s->as.local.values[j], p->ty)) continue;
            slot_kill(p, s->as.local.local_idxs[j]);
        }
        break;
    }
    case STMT_ASSIGN: {
        int nt = s->as.assign.n_targets, nv = s->as.assign.n_values;
        for (int j = 0; j < nt; j++) {
            const AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind != TGT_VAR || t->as.var.kind != VAR_LOCAL) continue;
            if (nt == 1 && nv == 1 && expr_has_ty(c, s->as.assign.values[0], p->ty)) continue;
            slot_kill(p, t->as.var.idx);
        }
        break;
    }
    case STMT_FOR_NUM:
        if (p->ty != NT_INT || !int_for_loop(c, s)) slot_kill(p, s->as.for_num.local_idx);
        break;
    case STMT_FOR_GEN:
        for (int j = 0; j < s->as.for_gen.n_names; j++) slot_kill(p, s->as.for_gen.local_idxs[j]);
        break;
    case STMT_LOCAL_FUNC: slot_kill(p, s->as.local_func.local_idx); break;
    default: break;
    }
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
        if (captured && captured[i]) {
            out[i] = 0;
            continue;
        }
        out[i] = (i >= n_params) ||
                 (param_seed && (param_seed[i] == NT_INT || param_seed[i] == NT_UNSET));
    }
    const unsigned char *saved = c->cur_is_int;
    int saved_n = c->cur_n_locals;
    c->cur_is_int = out;
    c->cur_n_locals = n_locals;
    SlotPass p = {.c = c, .out = out, .changed = 1, .ty = NT_INT};
    while (p.changed) {
        p.changed = 0;
        walk_stmts(body, typed_kill_stmt, &p);
    }
    c->cur_is_int = saved;
    c->cur_n_locals = saved_n;
}

/* Fill out[] with float-only slots. Run AFTER compute_int_slots (with the
 * final int bitmap live on c->cur_is_int, since expr_is_float consults
 * expr_is_int for mixed int/float operands). */
static void compute_float_slots(CG *c, const Block *body, int n_locals, int n_params,
                                const unsigned char *captured, unsigned char *out,
                                const NumTy *param_seed) {
    for (int i = 0; i < n_locals; i++) {
        if ((captured && captured[i]) || (c->cur_is_int && c->cur_is_int[i])) {
            out[i] = 0;
            continue;
        }
        out[i] = (i >= n_params) || (param_seed && param_seed[i] == NT_FLOAT);
    }
    const unsigned char *saved = c->cur_is_float;
    int saved_n = c->cur_n_locals;
    c->cur_is_float = out;
    c->cur_n_locals = n_locals;
    SlotPass p = {.c = c, .out = out, .changed = 1, .ty = NT_FLOAT};
    while (p.changed) {
        p.changed = 0;
        walk_stmts(body, typed_kill_stmt, &p);
    }
    c->cur_is_float = saved;
    c->cur_n_locals = saved_n;
}

/* ===== Maybe-typed numeric locals (docs/design/22-maybe-typed-locals.md) =====
 *
 * A local fed from opaque sources (table fields, calls, `x or 0`) can't be
 * proven int or float, but usually is one at runtime. Such a slot, when it is
 * also used in arithmetic or a comparison, is emitted as four wasm locals —
 * $Lt (tag: 0 boxed / 1 int / 2 float), $Li (i64), $Lf (f64), $L (anyref) —
 * classified once per store ($unbox_num) and consumed by a tag switch that
 * runs i64/f64 ops inline and falls back to the generic runtime helper (same
 * operands, same errors) for anything else. Boxing happens only where a real
 * Lua value is needed ($box_num). Nothing here changes what is computed, only
 * which path computes it; -O0 marks no slot maybe. */

static int maybe_arith_op(BinOp op) {
    switch (op) {
    case BIN_ADD:
    case BIN_SUB:
    case BIN_MUL:
    case BIN_DIV:
    case BIN_FDIV:
    case BIN_MOD: return 1;
    default: return 0;
    }
}

static int slot_is_maybe(const CG *c, int slot) {
    if (!c->opt_int || !c->cur_is_maybe) return 0;
    if (slot < 0 || slot >= c->cur_n_locals) return 0;
    return c->cur_is_maybe[slot];
}

/* Could `e` evaluate to a number? Anything not statically of another type.
 * `and`/`or` count (the `t.n or 0` idiom); concatenation, comparisons, `not`
 * and non-numeric literals/constructors don't. */
static int expr_numeric_plausible(const Expr *e) {
    switch (e->kind) {
    case EXPR_INT:
    case EXPR_FLOAT:
    case EXPR_VAR:
    case EXPR_CALL:
    case EXPR_METHOD_CALL:
    case EXPR_INDEX:
    case EXPR_VARARG: return 1;
    case EXPR_BINOP:
        switch (e->as.binop.op) {
        case BIN_CONCAT:
        case BIN_EQ:
        case BIN_NEQ:
        case BIN_LT:
        case BIN_LE:
        case BIN_GT:
        case BIN_GE: return 0;
        default: return 1;
        }
    case EXPR_UNOP: return e->as.unop.op != UN_NOT;
    default: return 0;
    }
}

/* Operand classification for the lowering decision. "Opaque": a value the
 * runtime classifies rather than the compiler proves — a maybe slot, any
 * other untyped variable, a table read or a call; recursion goes through
 * arithmetic / comparison / unary-minus nodes. "Numeric evidence": something
 * that makes a number likely — a numeric literal, a provably typed
 * expression, a maybe slot, or an arithmetic node. */
static int expr_has_opaque(CG *c, const Expr *e) {
    switch (e->kind) {
    case EXPR_VAR:
        if (e->as.var.kind == VAR_LOCAL)
            return slot_is_maybe(c, e->as.var.idx) ||
                   (!slot_is_int(c, e->as.var.idx) && !slot_is_float(c, e->as.var.idx));
        return 1;
    case EXPR_INDEX:
    case EXPR_CALL:
    case EXPR_METHOD_CALL: return 1;
    case EXPR_BINOP:
        if (!maybe_arith_op(e->as.binop.op) && !is_cmp_op(e->as.binop.op)) return 0;
        return expr_has_opaque(c, e->as.binop.lhs) || expr_has_opaque(c, e->as.binop.rhs);
    case EXPR_UNOP: return e->as.unop.op == UN_NEG && expr_has_opaque(c, e->as.unop.operand);
    default: return 0;
    }
}
static int expr_numeric_evidence(CG *c, const Expr *e) {
    switch (e->kind) {
    case EXPR_INT:
    case EXPR_FLOAT: return 1;
    case EXPR_VAR:
        return e->as.var.kind == VAR_LOCAL &&
               (slot_is_maybe(c, e->as.var.idx) || slot_is_int(c, e->as.var.idx) ||
                slot_is_float(c, e->as.var.idx));
    case EXPR_BINOP:
        if (maybe_arith_op(e->as.binop.op)) return 1;
        if (!is_cmp_op(e->as.binop.op)) return 0;
        return expr_numeric_evidence(c, e->as.binop.lhs) || expr_numeric_evidence(c, e->as.binop.rhs);
    case EXPR_UNOP: return e->as.unop.op == UN_NEG;
    case EXPR_CALL: return expr_is_int(c, e) || expr_is_float(c, e);
    default: return 0;
    }
}

/* A tree is lowered by the maybe machinery iff it is an arithmetic binop or
 * a unary minus with an opaque operand, or a comparison with an opaque
 * operand AND numeric evidence on some side (so `x == nil` or `a == b` on
 * two unknowns keep the plain generic call instead of paying to classify).
 * (A bare operand answers per expr_has_opaque; callers ask about operator
 * nodes.) */
static int expr_involves_maybe(CG *c, const Expr *e) {
    if (!c->opt_int || !c->cur_is_maybe) return 0;
    if (e->kind == EXPR_BINOP && is_cmp_op(e->as.binop.op))
        return expr_has_opaque(c, e) &&
               (expr_numeric_evidence(c, e->as.binop.lhs) || expr_numeric_evidence(c, e->as.binop.rhs));
    return expr_has_opaque(c, e);
}

/* --- numeric-use analysis: which slots are read inside an arithmetic,
 * comparison or unary-minus tree (through such nodes only) [use], or directly
 * as the key of a table read [key] — an integer key then reaches the array
 * part unboxed through $lua_index_mk / $lua_tabset_mk, and a non-number one
 * just stays boxed --- */
typedef struct {
    unsigned char *use;
    unsigned char *key;
    int n;
} NumUse;
static void numuse_expr(const Expr *e, NumUse *u, int in_arith);
static void numuse_child(const Expr *e, NumUse *u) { numuse_expr(e, u, 0); }
static void numuse_expr(const Expr *e, NumUse *u, int in_arith) {
    if (!e) return;
    switch (e->kind) {
    case EXPR_VAR:
        if (in_arith && e->as.var.kind == VAR_LOCAL && e->as.var.idx >= 0 && e->as.var.idx < u->n)
            u->use[e->as.var.idx] = 1;
        return;
    case EXPR_BINOP:
        if (maybe_arith_op(e->as.binop.op) || is_cmp_op(e->as.binop.op)) {
            numuse_expr(e->as.binop.lhs, u, 1);
            numuse_expr(e->as.binop.rhs, u, 1);
        } else {
            numuse_child(e->as.binop.lhs, u);
            numuse_child(e->as.binop.rhs, u);
        }
        return;
    case EXPR_UNOP: numuse_expr(e->as.unop.operand, u, e->as.unop.op == UN_NEG); return;
    case EXPR_CALL:
        numuse_child(e->as.call.callee, u);
        for (size_t i = 0; i < e->as.call.nargs; i++) numuse_child(e->as.call.args[i], u);
        return;
    case EXPR_METHOD_CALL:
        numuse_child(e->as.method_call.recv, u);
        for (size_t i = 0; i < e->as.method_call.nargs; i++) numuse_child(e->as.method_call.args[i], u);
        return;
    case EXPR_INDEX:
        numuse_child(e->as.index.table, u);
        if (e->as.index.key->kind == EXPR_VAR && e->as.index.key->as.var.kind == VAR_LOCAL &&
            e->as.index.key->as.var.idx >= 0 && e->as.index.key->as.var.idx < u->n)
            u->key[e->as.index.key->as.var.idx] = 1;
        else numuse_child(e->as.index.key, u);
        return;
    case EXPR_TABLE:
        for (int i = 0; i < e->as.table_ctor.n_entries; i++) {
            if (e->as.table_ctor.entries[i].key) numuse_child(e->as.table_ctor.entries[i].key, u);
            numuse_child(e->as.table_ctor.entries[i].value, u);
        }
        return;
    default: return;
    }
}
static void numuse_visit(const Expr *e, void *ctx) { numuse_expr(e, (NumUse *)ctx, 0); }

/* An expression whose evaluation has no side effects and reads no mutable
 * state that another operand's evaluation could change: literals, and
 * arithmetic / unary minus over literals and local variables. Used to decide
 * whether a left operand read in place must instead be copied before the
 * right operand runs. */
static int expr_side_effect_free(const Expr *e) {
    switch (e->kind) {
    case EXPR_INT:
    case EXPR_FLOAT:
    case EXPR_NIL:
    case EXPR_TRUE:
    case EXPR_FALSE:
    case EXPR_STRING: return 1;
    case EXPR_VAR: return e->as.var.kind == VAR_LOCAL;
    case EXPR_BINOP:
        return (maybe_arith_op(e->as.binop.op) || is_cmp_op(e->as.binop.op)) &&
               expr_side_effect_free(e->as.binop.lhs) && expr_side_effect_free(e->as.binop.rhs);
    case EXPR_UNOP: return e->as.unop.op == UN_NEG && expr_side_effect_free(e->as.unop.operand);
    default: return 0;
    }
}

/* If `e` can be an operand without a temporary — a numeric literal, a typed
 * local, or a maybe slot read in place — fill `out` and return 1. A variable
 * read is only used in place when the operand evaluated after it
 * (`other_after`, NULL if none) cannot modify it. */
static int operand_immediate(CG *c, const Expr *e, const Expr *other_after, MCell *out) {
    switch (e->kind) {
    case EXPR_INT:
        if (out) *out = mcell_imm_int(e->as.i_val);
        return 1;
    case EXPR_FLOAT:
        if (out) *out = mcell_imm_float(e->as.f_val);
        return 1;
    case EXPR_VAR:
        if (e->as.var.kind != VAR_LOCAL) return 0;
        if (other_after && !expr_side_effect_free(other_after)) return 0;
        if (slot_is_int(c, e->as.var.idx)) {
            if (out) *out = mcell_typed_local(e->as.var.idx, 0);
            return 1;
        }
        if (slot_is_float(c, e->as.var.idx)) {
            if (out) *out = mcell_typed_local(e->as.var.idx, 1);
            return 1;
        }
        if (slot_is_maybe(c, e->as.var.idx)) {
            if (out) *out = mcell_slot(e->as.var.idx);
            return 1;
        }
        return 0;
    default: return 0;
    }
}

/* --- lowering temporaries: an upper bound on how many a body needs.
 * Lowering a binop takes a temporary per non-immediate operand above the
 * current depth and lowers each such operand above those; a unary minus
 * likewise; an opaque node's child lowered in a boxed context takes one for
 * its root. --- */
static int expr_temp_need(CG *c, const Expr *e) {
    if (!e) return 0;
    int m = 0, v;
    switch (e->kind) {
    case EXPR_BINOP: {
        const Expr *l = e->as.binop.lhs, *r = e->as.binop.rhs;
        int tl = !operand_immediate(c, l, r, NULL), tr = !operand_immediate(c, r, NULL, NULL);
        int nl = tl ? expr_temp_need(c, l) : 0, nr = tr ? expr_temp_need(c, r) : 0;
        return tl + tr + (nl > nr ? nl : nr);
    }
    case EXPR_UNOP: {
        const Expr *o = e->as.unop.operand;
        int t = !operand_immediate(c, o, NULL, NULL);
        return t + (t ? expr_temp_need(c, o) : 0);
    }
    case EXPR_CALL:
        m = 1 + expr_temp_need(c, e->as.call.callee);
        for (size_t i = 0; i < e->as.call.nargs; i++)
            if ((v = 2 + expr_temp_need(c, e->as.call.args[i])) > m) m = v; /* +1 callee cell for inline math */
        return m;
    case EXPR_METHOD_CALL:
        m = 1 + expr_temp_need(c, e->as.method_call.recv);
        for (size_t i = 0; i < e->as.method_call.nargs; i++)
            if ((v = 1 + expr_temp_need(c, e->as.method_call.args[i])) > m) m = v;
        return m;
    case EXPR_INDEX:
        m = 1 + expr_temp_need(c, e->as.index.table);
        if ((v = 1 + expr_temp_need(c, e->as.index.key)) > m) m = v;
        return m;
    case EXPR_TABLE:
        for (int i = 0; i < e->as.table_ctor.n_entries; i++) {
            if (e->as.table_ctor.entries[i].key &&
                (v = 1 + expr_temp_need(c, e->as.table_ctor.entries[i].key)) > m)
                m = v;
            if ((v = 1 + expr_temp_need(c, e->as.table_ctor.entries[i].value)) > m) m = v;
        }
        return m;
    default: return 0;
    }
}
typedef struct {
    CG *c;
    int m;
} TempNeed;
static void temp_need_visit(const Expr *e, void *ctx) {
    TempNeed *t = (TempNeed *)ctx;
    int v = 1 + expr_temp_need(t->c, e);
    if (v > t->m) t->m = v;
}
/* emit_assign_multi_cells holds a table and a key cell per index target and a
 * value cell per value while it evaluates the next sub-expression above them. */
static int multi_assign_stmt_need(CG *c, const Stmt *s) {
    int v;
    switch (s->kind) {
    case STMT_ASSIGN: {
        int nt = s->as.assign.n_targets, nv = s->as.assign.n_values;
        if (nt < 2 || nv != nt) return 0;
        int live = nv, sub = 0;
        for (int i = 0; i < nt; i++) {
            const AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind == TGT_VAR) continue;
            live += 2;
            if ((v = 1 + expr_temp_need(c, t->as.index.table)) > sub) sub = v;
            if ((v = 1 + expr_temp_need(c, t->as.index.key)) > sub) sub = v;
        }
        for (int i = 0; i < nv; i++)
            if ((v = 1 + expr_temp_need(c, s->as.assign.values[i])) > sub) sub = v;
        return live + sub;
    }
    default: return 0;
    }
}
static void multi_assign_need_visit(const Stmt *s, void *ctx) {
    TempNeed *t = ctx;
    int v = multi_assign_stmt_need(t->c, s);
    if (v > t->m) t->m = v;
}
static int block_temp_need(CG *c, const Block *b) {
    TempNeed t = {.c = c, .m = 0};
    walk_block_exprs(b, temp_need_visit, &t);
    walk_stmts(b, multi_assign_need_visit, &t);
    return t.m + 2; /* + the table and value cells of an unboxed store */
}

/* A candidate used numerically only as a table key pays a classification on
 * every store, which is only worth it when the stored values are likely
 * numbers: a call result (`local k = key(x, y)`) is more often a string key,
 * so such a store disqualifies it; a table read (`local id = alive[i]`) or
 * arithmetic keeps it. */
static int key_store_ok(const CG *c, int slot, const Expr *v) {
    if (!c->maybe_key_only || slot < 0 || slot >= c->cur_n_locals || !c->maybe_key_only[slot]) return 1;
    return v->kind != EXPR_CALL && v->kind != EXPR_METHOD_CALL && v->kind != EXPR_VARARG;
}

/* --- kill rules: a candidate survives only if every store to it is a single
 * numeric-plausible value on a path emit_maybe_store handles. --- */
static void maybe_kill_stmt(const Stmt *s, void *ctx) {
    SlotPass *p = ctx;
    CG *c = p->c;
    switch (s->kind) {
    case STMT_LOCAL: {
        int nn = s->as.local.n_names, nv = s->as.local.n_values;
        int last_call = nv > 0 && is_multival_tail(s->as.local.values[nv - 1]);
        int n_lead = last_call ? nv - 1 : nv;
        for (int j = 0; j < nn; j++) {
            int slot = s->as.local.local_idxs[j];
            if (s->as.local.attribs && s->as.local.attribs[j] == 2) {
                slot_kill(p, slot);
                continue;
            }
            /* A leading value, or a trailing call whose FIRST value lands on
             * exactly the last name (`local m = sqrt(x)`): a single store. */
            int single = j < n_lead || (last_call && j == nv - 1 && nn == nv);
            if (single && key_store_ok(c, slot, s->as.local.values[j]) &&
                expr_numeric_plausible(s->as.local.values[j]))
                continue;
            slot_kill(p, slot);
        }
        break;
    }
    case STMT_ASSIGN: {
        int nt = s->as.assign.n_targets, nv = s->as.assign.n_values;
        for (int j = 0; j < nt; j++) {
            AssignTarget *t = &s->as.assign.targets[j];
            if (t->kind != TGT_VAR || t->as.var.kind != VAR_LOCAL) continue;
            if (nt == 1 && nv == 1 && key_store_ok(c, t->as.var.idx, s->as.assign.values[0]) &&
                expr_numeric_plausible(s->as.assign.values[0]))
                continue;
            slot_kill(p, t->as.var.idx);
        }
        break;
    }
    case STMT_FOR_NUM: slot_kill(p, s->as.for_num.local_idx); break;
    case STMT_FOR_GEN:
        for (int j = 0; j < s->as.for_gen.n_names; j++) slot_kill(p, s->as.for_gen.local_idxs[j]);
        break;
    case STMT_LOCAL_FUNC: slot_kill(p, s->as.local_func.local_idx); break;
    default: break;
    }
}

/* Fill out[] with the maybe-typed slots of one body. Run AFTER the int and
 * float analyses (both bitmaps live on c). Candidates: non-parameter,
 * non-captured, not already typed, read at least once in a numeric position;
 * then the kill fixpoint over stores. Returns whether any slot survived. */
static int compute_maybe_slots(CG *c, const Block *body, int n_locals, int n_params,
                               const unsigned char *captured, unsigned char *out) {
    NumUse u = {.use = calloc(n_locals ? n_locals : 1, 1), .key = calloc(n_locals ? n_locals : 1, 1), .n = n_locals};
    walk_block_exprs(body, numuse_visit, &u);
    /* Parameters are candidates too (classified at entry), but not on key use
     * alone: classifying on every call doesn't pay for a single unboxed key
     * (e.g. a sort comparator's `py[a] < py[b]`). A local's store is the
     * table read itself, which the cell reader classifies for free. */
    for (int i = 0; i < n_locals; i++) {
        out[i] = !(captured && captured[i]) &&
                 !(c->cur_is_int && c->cur_is_int[i]) && !(c->cur_is_float && c->cur_is_float[i]) &&
                 (u.use[i] || (u.key[i] && i >= n_params));
    }
    for (int i = 0; i < n_locals; i++) u.key[i] = u.key[i] && !u.use[i];
    free(u.use);
    int saved_n = c->cur_n_locals;
    c->cur_n_locals = n_locals;
    c->maybe_key_only = u.key;
    SlotPass p = {.c = c, .out = out, .changed = 1};
    while (p.changed) {
        p.changed = 0;
        walk_stmts(body, maybe_kill_stmt, &p);
    }
    c->maybe_key_only = NULL;
    free(u.key);
    c->cur_n_locals = saved_n;
    int any = 0;
    for (int i = 0; i < n_locals; i++) any |= out[i];
    return any;
}

/* --- emission --- */

static int mt_alloc(CG *c, int n) {
    int k = c->mt_depth;
    c->mt_depth += n;
    if (c->mt_depth > c->mt_max) cg_error(c, "internal: maybe-typed temporaries exceed the pre-pass bound");
    return k;
}
static void emit_set_tag(CG *c, const MCell *m, int tag, int depth) {
    emit_linef(c, depth, "(local.set %s (i32.const %d))\n", m->st, tag);
}
/* `(call $box_num tag i f b)` — the cell as a Lua value. */
static void emit_maybe_cell_box(CG *c, const MCell *m, int depth) {
    emit_linef(c, depth, "(call $box_num %s %s %s %s)\n", m->t, m->i, m->f, m->b);
}
static void emit_maybe_slot_box(CG *c, int slot, int depth) {
    MCell m = mcell_slot(slot);
    emit_maybe_cell_box(c, &m, depth);
}
/* The f64 view of a cell known to be numeric (tag 1 or 2). */
static void emit_cell_f64(CG *c, const MCell *m, int depth) {
    emit_linef(c, depth, "(if (result f64) (i32.eq %s (i32.const 2)) (then %s) (else (f64.convert_i64_s %s)))\n",
               m->t, m->f, m->i);
}
static void emit_both_tags(CG *c, const MCell *a, const MCell *b, int tag, int depth) {
    emit_linef(c, depth, "(i32.and (i32.eq %s (i32.const %d)) (i32.eq %s (i32.const %d)))\n", a->t, tag, b->t, tag);
}
/* d = generic helper(box a, box b); tag 0. */
static void emit_maybe_generic2(CG *c, const char *helper, const MCell *a, const MCell *b,
                                const MCell *d, int depth) {
    emit_linef(c, depth, "(local.set %s (call %s\n", d->sb, helper);
    emit_maybe_cell_box(c, a, depth + 1);
    emit_maybe_cell_box(c, b, depth + 1);
    emit_line(c, depth, "))\n");
    emit_set_tag(c, d, 0, depth);
}

static void emit_maybe_lower(CG *c, const Expr *e, const MCell *d, int depth);

/* Evaluate the two operands of a lowered binop left to right into cells:
 * immediates in place, anything else into a fresh temporary. Returns the
 * temporary depth to restore once the result has been computed. */
static int emit_maybe_operands(CG *c, const Expr *l, const Expr *r, MCell *a, MCell *b, int depth) {
    int k = c->mt_depth;
    int il = operand_immediate(c, l, r, a), ir = operand_immediate(c, r, NULL, b);
    int next = k;
    if (!il) *a = mcell_tmp(next++);
    if (!ir) *b = mcell_tmp(next++);
    mt_alloc(c, next - k);
    if (!il) emit_maybe_lower(c, l, a, depth);
    if (!ir) emit_maybe_lower(c, r, b, depth);
    return k;
}

/* d = a <op> b over two cells: int×int inline (i64; `/` converts to f64;
 * `//` `%` via the floor helpers), numeric with a float side inline for
 * + - * /, everything else through the generic helper. */
static void emit_maybe_arith(CG *c, BinOp op, const MCell *a, const MCell *b, const MCell *d, int depth) {
    const char *iop = NULL, *ifn = NULL, *fop = NULL;
    switch (op) {
    case BIN_ADD: iop = "i64.add", fop = "f64.add"; break;
    case BIN_SUB: iop = "i64.sub", fop = "f64.sub"; break;
    case BIN_MUL: iop = "i64.mul", fop = "f64.mul"; break;
    case BIN_DIV: fop = "f64.div"; break;
    case BIN_FDIV: ifn = "$idiv_floor"; break;
    case BIN_MOD: ifn = "$imod_floor"; break;
    default: cg_error(c, "internal: emit_maybe_arith on a non-arithmetic op"); return;
    }
    emit_line(c, depth, "(if\n");
    emit_both_tags(c, a, b, 1, depth + 1);
    emit_line(c, depth + 1, "(then\n");
    emit_indent(c, depth + 2);
    if (op == BIN_DIV) {
        wat_appendf(c->w, "(local.set %s (f64.div (f64.convert_i64_s %s) (f64.convert_i64_s %s)))\n", d->sf, a->i, b->i);
        emit_set_tag(c, d, 2, depth + 2);
    } else if (ifn) {
        wat_appendf(c->w, "(local.set %s (call %s %s %s))\n", d->si, ifn, a->i, b->i);
        emit_set_tag(c, d, 1, depth + 2);
    } else {
        wat_appendf(c->w, "(local.set %s (%s %s %s))\n", d->si, iop, a->i, b->i);
        emit_set_tag(c, d, 1, depth + 2);
    }
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth + 1, "(else\n");
    if (fop) {
        emit_linef(c, depth + 2, "(if (i32.and (i32.ne %s (i32.const 0)) (i32.ne %s (i32.const 0)))\n", a->t, b->t);
        emit_line(c, depth + 3, "(then\n");
        emit_linef(c, depth + 4, "(local.set %s (%s\n", d->sf, fop);
        emit_cell_f64(c, a, depth + 5);
        emit_cell_f64(c, b, depth + 5);
        emit_line(c, depth + 4, "))\n");
        emit_set_tag(c, d, 2, depth + 4);
        emit_line(c, depth + 3, ")\n");
        emit_line(c, depth + 3, "(else\n");
        emit_maybe_generic2(c, binop_helper(op), a, b, d, depth + 4);
        emit_line(c, depth + 3, "))\n");
    } else {
        emit_maybe_generic2(c, binop_helper(op), a, b, d, depth + 2);
    }
    emit_line(c, depth + 1, "))\n");
}

static void emit_maybe_neg(CG *c, const MCell *a, const MCell *d, int depth) {
    emit_linef(c, depth, "(if (i32.eq %s (i32.const 1))\n", a->t);
    emit_linef(c, depth + 1, "(then (local.set %s (i64.sub (i64.const 0) %s))\n", d->si, a->i);
    emit_set_tag(c, d, 1, depth + 2);
    emit_linef(c, depth + 1, ")\n");
    emit_linef(c, depth + 1, "(else (if (i32.eq %s (i32.const 2))\n", a->t);
    emit_linef(c, depth + 2, "(then (local.set %s (f64.neg %s))\n", d->sf, a->f);
    emit_set_tag(c, d, 2, depth + 3);
    emit_line(c, depth + 2, ")\n");
    emit_line(c, depth + 2, "(else\n");
    emit_linef(c, depth + 3, "(local.set %s (call $lua_neg\n", d->sb);
    emit_maybe_cell_box(c, a, depth + 4);
    emit_line(c, depth + 3, "))\n");
    emit_set_tag(c, d, 0, depth + 3);
    emit_line(c, depth + 2, "))))\n");
}

/* --- inline math builtins ---
 * `sqrt(x)` / `math.floor(x)` and friends in a lowered tree: the callee is
 * evaluated as usual, then a runtime identity check against the builtin's
 * closure global guards an inline f64.sqrt / abs / floor / ceil on a numeric
 * argument; any other callee or argument takes the ordinary call. The
 * decision of WHERE to emit the guard comes from the callee expression
 * (`math.<key>`) or, for a local / upvalue, from its declaration's
 * initializer — a heuristic only, the guard carries the correctness. */
typedef enum { MB_NONE = 0,
               MB_SQRT,
               MB_ABS,
               MB_FLOOR,
               MB_CEIL } MathBuiltin;
static const struct {
    const char *key;
    MathBuiltin kind;
} MATH_INLINE[] = {{"sqrt", MB_SQRT}, {"abs", MB_ABS}, {"floor", MB_FLOOR}, {"ceil", MB_CEIL}};

static MathBuiltin math_index_kind(CG *c, const Expr *e) {
    if (e->kind != EXPR_INDEX) return MB_NONE;
    const Expr *t = e->as.index.table, *k = e->as.index.key;
    if (t->kind != EXPR_VAR || t->as.var.kind != VAR_GLOBAL) return MB_NONE;
    if (c->pr->globals.items[t->as.var.idx].name_len != 4 ||
        memcmp(c->pr->globals.items[t->as.var.idx].name, "math", 4) != 0)
        return MB_NONE;
    if (k->kind != EXPR_STRING) return MB_NONE;
    for (size_t i = 0; i < sizeof(MATH_INLINE) / sizeof(MATH_INLINE[0]); i++)
        if (strlen(MATH_INLINE[i].key) == k->as.s.len && memcmp(MATH_INLINE[i].key, k->as.s.bytes, k->as.s.len) == 0)
            return MATH_INLINE[i].kind;
    return MB_NONE;
}

/* The initializer of the `local` statement declaring `slot` in `b`, if it
 * is a single-valued position; NULL otherwise. */
typedef struct {
    int slot, found;
    const Expr *init;
} LocalInit;
static void find_local_init_visit(const Stmt *s, void *ctx) {
    LocalInit *li = ctx;
    if (li->found || s->kind != STMT_LOCAL) return;
    int nn = s->as.local.n_names, nv = s->as.local.n_values;
    int last_call = nv > 0 && is_multival_tail(s->as.local.values[nv - 1]);
    int n_lead = last_call ? nv - 1 : nv;
    for (int j = 0; j < nn; j++)
        if (s->as.local.local_idxs[j] == li->slot) {
            li->found = 1;
            li->init = j < n_lead ? s->as.local.values[j] : NULL;
            return;
        }
}
static const Expr *find_local_init_block(const Block *b, int slot) {
    LocalInit li = {.slot = slot};
    walk_stmts(b, find_local_init_visit, &li);
    return li.init;
}

static MathBuiltin callee_math_kind(CG *c, const Expr *callee) {
    MathBuiltin k = math_index_kind(c, callee);
    if (k || callee->kind != EXPR_VAR) return k;
    const Block *body;
    int slot;
    if (callee->as.var.kind == VAR_LOCAL) {
        body = c->cur_func_idx < 0 ? &c->pr->main_body : &c->pr->funcs.items[c->cur_func_idx]->body;
        slot = callee->as.var.idx;
    } else if (callee->as.var.kind == VAR_UPVAL && c->cur_func_idx >= 0) {
        int of, os;
        resolve_upval_origin(c, c->cur_func_idx, callee->as.var.idx, &of, &os);
        if (of == -2) return MB_NONE;
        body = of < 0 ? &c->pr->main_body : &c->pr->funcs.items[of]->body;
        slot = os;
    } else {
        return MB_NONE;
    }
    const Expr *init = find_local_init_block(body, slot);
    return init ? math_index_kind(c, init) : MB_NONE;
}

/* The wasm global holding the builtin closure for math.<key>. */
static const char *math_builtin_global(MathBuiltin k) {
    const char *key = MATH_INLINE[k - 1].key;
    int nb = builtin_count();
    for (int i = 0; i < nb; i++)
        if (builtin_class(i) == BLT_LIB_MATH && strcmp(builtin_lib_key(i), key) == 0) return builtin_func_name(i) + 1;
    return NULL;
}

static void emit_maybe_lower(CG *c, const Expr *e, const MCell *d, int depth);

/* d = <math builtin>(arg) with the guarded inline fast path. */
static void emit_maybe_math_call(CG *c, const Expr *e, MathBuiltin mk, const MCell *d, int depth) {
    const char *glob = math_builtin_global(mk);
    if (!glob) {
        cg_error(c, "internal: math builtin global not found");
        return;
    }
    int k = c->mt_depth;
    MCell cv = mcell_tmp(k); /* the callee, never the destination (d may be the arg) */
    mt_alloc(c, 1);
    emit_linef(c, depth, "(local.set %s\n", cv.sb);
    emit_expr(c, e->as.call.callee, depth + 1);
    emit_line(c, depth, ")\n");
    MCell a;
    if (!operand_immediate(c, e->as.call.args[0], NULL, &a)) {
        a = mcell_tmp(k + 1);
        mt_alloc(c, 1);
        emit_maybe_lower(c, e->as.call.args[0], &a, depth);
    }
    emit_linef(c, depth, "(if (i32.and (ref.eq (ref.cast (ref null eq) %s) (global.get $g_%s)) (i32.ne %s (i32.const 0)))\n",
               cv.b, glob, a.t);
    emit_line(c, depth + 1, "(then\n");
    switch (mk) {
    case MB_SQRT:
        emit_linef(c, depth + 2, "(local.set %s (f64.sqrt\n", d->sf);
        emit_cell_f64(c, &a, depth + 3);
        emit_line(c, depth + 2, "))\n");
        emit_set_tag(c, d, 2, depth + 2);
        break;
    case MB_ABS:
        emit_linef(c, depth + 2, "(if (i32.eq %s (i32.const 1))\n", a.t);
        emit_linef(c, depth + 3, "(then (local.set %s (select (i64.sub (i64.const 0) %s) %s (i64.lt_s %s (i64.const 0))))\n",
                   d->si, a.i, a.i, a.i);
        emit_set_tag(c, d, 1, depth + 4);
        emit_line(c, depth + 3, ")\n");
        emit_linef(c, depth + 3, "(else (local.set %s (f64.abs %s))\n", d->sf, a.f);
        emit_set_tag(c, d, 2, depth + 4);
        emit_line(c, depth + 3, "))\n");
        break;
    case MB_FLOOR:
    case MB_CEIL:
        /* An int is its own floor; a float rounds and converts to an
         * integer when it fits (reference pushnumint), else stays float. */
        emit_linef(c, depth + 2, "(if (i32.eq %s (i32.const 1))\n", a.t);
        emit_linef(c, depth + 3, "(then (local.set %s %s)\n", d->si, a.i);
        emit_set_tag(c, d, 1, depth + 4);
        emit_line(c, depth + 3, ")\n");
        emit_linef(c, depth + 3, "(else (local.set %s (%s %s))\n", d->sf, mk == MB_FLOOR ? "f64.floor" : "f64.ceil", a.f);
        emit_linef(c, depth + 4, "(if (i32.and (f64.ge %s (f64.const -9223372036854775808)) (f64.lt %s (f64.const 9223372036854775808)))\n",
                   d->f, d->f);
        emit_linef(c, depth + 5, "(then (local.set %s (i64.trunc_f64_s %s))\n", d->si, d->f);
        emit_set_tag(c, d, 1, depth + 6);
        emit_line(c, depth + 5, ")\n");
        emit_line(c, depth + 5, "(else\n");
        emit_set_tag(c, d, 2, depth + 6);
        emit_line(c, depth + 5, "))\n");
        emit_line(c, depth + 3, "))\n");
        break;
    default: break;
    }
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth + 1, "(else\n");
    emit_linef(c, depth + 2, "(local.set %s (call $args_first (call $lua_call_any %s (array.new_fixed $ArgArr 1\n", d->sb, cv.b);
    emit_maybe_cell_box(c, &a, depth + 3);
    emit_linef(c, depth + 2, ") (i32.const %d))))\n", e->line);
    emit_linef(c, depth + 2, "(call $unbox_num %s)\n", d->b);
    emit_linef(c, depth + 2, "local.set %s\n", d->sf);
    emit_linef(c, depth + 2, "local.set %s\n", d->si);
    emit_linef(c, depth + 2, "local.set %s\n", d->st);
    emit_line(c, depth + 1, "))\n");
    c->mt_depth = k;
}

/* Lower `e` into cell `d` as a statement sequence. Provably typed
 * subexpressions keep their unboxed paths; a maybe read is a cell copy;
 * arithmetic and unary minus recurse; anything else is evaluated as a Lua
 * value and classified once. */
static void emit_maybe_lower(CG *c, const Expr *e, const MCell *d, int depth) {
    if (!c->ok) return;
    if (expr_is_int(c, e)) {
        emit_linef(c, depth, "(local.set %s\n", d->si);
        emit_int_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        emit_set_tag(c, d, 1, depth);
        return;
    }
    if (expr_is_float(c, e)) {
        emit_linef(c, depth, "(local.set %s\n", d->sf);
        emit_float_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        emit_set_tag(c, d, 2, depth);
        return;
    }
    switch (e->kind) {
    case EXPR_VAR:
        if (e->as.var.kind == VAR_LOCAL && slot_is_maybe(c, e->as.var.idx)) {
            MCell src = mcell_slot(e->as.var.idx);
            if (strcmp(src.st, d->st) == 0) return; /* x = x */
            emit_linef(c, depth, "(local.set %s %s)\n", d->st, src.t);
            emit_linef(c, depth, "(local.set %s %s)\n", d->si, src.i);
            emit_linef(c, depth, "(local.set %s %s)\n", d->sf, src.f);
            emit_linef(c, depth, "(local.set %s %s)\n", d->sb, src.b);
            return;
        }
        break;
    case EXPR_BINOP:
        if (maybe_arith_op(e->as.binop.op)) {
            MCell a, b;
            int k = emit_maybe_operands(c, e->as.binop.lhs, e->as.binop.rhs, &a, &b, depth);
            emit_maybe_arith(c, e->as.binop.op, &a, &b, d, depth);
            c->mt_depth = k;
            return;
        }
        break;
    case EXPR_CALL: {
        MathBuiltin mk;
        if (e->as.call.nargs == 1 && !is_multival_tail(e->as.call.args[0]) &&
            (mk = callee_math_kind(c, e->as.call.callee)) != MB_NONE) {
            emit_maybe_math_call(c, e, mk, d, depth);
            return;
        }
        break;
    }
    case EXPR_INDEX: {
        /* A table read straight into the cell: an unboxed float slot arrives
         * as tag 2 with no allocation, anything else classified once. */
        const Expr *key = e->as.index.key;
        int kstr = key->kind == EXPR_STRING && key->as.s.len <= KSTR_MAX;
        int kint = !kstr && expr_is_int(c, key);
        int kmaybe = !kstr && !kint && key->kind == EXPR_VAR && key->as.var.kind == VAR_LOCAL &&
                     slot_is_maybe(c, key->as.var.idx);
        if (kstr || kint || kmaybe) {
            char icb[48];
            const char *ic = kstr ? ic_new(c, icb, sizeof icb) : NULL;
            emit_line(c, depth, kstr ? (ic ? "(call $lua_index_ic_cell\n" : "(call $lua_index_sk_cell\n") : kint ? "(call $lua_index_ik_cell\n"
                                                                                                                 : "(call $lua_index_mk_cell\n");
            emit_expr(c, e->as.index.table, depth + 1);
            if (kstr) {
                emit_string_literal(c, key->as.s.bytes, key->as.s.len, depth + 1);
            } else if (kint) {
                emit_int_expr(c, key, depth + 1);
            } else {
                MCell kc = mcell_slot(key->as.var.idx);
                emit_linef(c, depth + 1, "%s %s %s %s\n", kc.t, kc.i, kc.f, kc.b);
            }
            emit_linef(c, depth + 1, "(i32.const %d)%s%s\n", e->line, ic ? " " : "", ic ? ic : "");
            emit_line(c, depth, ")\n");
            emit_linef(c, depth, "local.set %s\n", d->sb);
            emit_linef(c, depth, "local.set %s\n", d->sf);
            emit_linef(c, depth, "local.set %s\n", d->si);
            emit_linef(c, depth, "local.set %s\n", d->st);
            return;
        }
        break;
    }
    case EXPR_UNOP:
        if (e->as.unop.op == UN_NEG) {
            int k = c->mt_depth;
            MCell a;
            if (!operand_immediate(c, e->as.unop.operand, NULL, &a)) {
                mt_alloc(c, 1);
                a = mcell_tmp(k);
                emit_maybe_lower(c, e->as.unop.operand, &a, depth);
            }
            emit_maybe_neg(c, &a, d, depth);
            c->mt_depth = k;
            return;
        }
        break;
    default: break;
    }
    /* Opaque: a Lua value, classified once. */
    emit_linef(c, depth, "(local.set %s\n", d->sb);
    emit_expr(c, e, depth + 1);
    emit_line(c, depth, ")\n");
    emit_linef(c, depth, "(call $unbox_num %s)\n", d->b);
    emit_linef(c, depth, "local.set %s\n", d->sf);
    emit_linef(c, depth, "local.set %s\n", d->si);
    emit_linef(c, depth, "local.set %s\n", d->st);
}

/* `slot = e` for a maybe slot. */
static void emit_maybe_store(CG *c, int slot, const Expr *e, int depth) {
    MCell d = mcell_slot(slot);
    emit_maybe_lower(c, e, &d, depth);
}

/* A lowered arithmetic tree in a Lua-value context:
 *   (block (result anyref) <lower into a temporary> (call $box_num …)) */
static void emit_maybe_boxed(CG *c, const Expr *e, int depth) {
    int k = mt_alloc(c, 1);
    MCell d = mcell_tmp(k);
    emit_line(c, depth, "(block (result anyref)\n");
    emit_maybe_lower(c, e, &d, depth + 1);
    emit_maybe_cell_box(c, &d, depth + 1);
    emit_line(c, depth, ")\n");
    c->mt_depth = k;
}

/* Static tag of a cell whose type is fixed at compile time (an immediate or
 * a typed local): 1 int, 2 float; 0 when only known at run time. */
static int mcell_static_tag(const MCell *m) {
    if (strcmp(m->t, "(i32.const 1)") == 0) return 1;
    if (strcmp(m->t, "(i32.const 2)") == 0) return 2;
    return 0;
}

/* The mixed int/float compare of cells a (lhs) and b (rhs), one int and one
 * float, as an i32: an f64 compare when the int side is an exactly
 * representable literal, else the exact helper. */
static void emit_mixed_cell_cmp(CG *c, const CmpOp *op, const Expr *e, const MCell *a, const MCell *b,
                                int int_left, int depth) {
    const MCell *ic = int_left ? a : b, *fc = int_left ? b : a;
    if (expr_is_exact_f64_int_literal(int_left ? e->as.binop.lhs : e->as.binop.rhs)) {
        if (int_left) emit_linef(c, depth, "(%s (f64.convert_i64_s %s) %s)\n", op->f64, ic->i, fc->f);
        else emit_linef(c, depth, "(%s %s (f64.convert_i64_s %s))\n", op->f64, fc->f, ic->i);
    } else {
        emit_linef(c, depth, "%s(call %s %s %s)%s\n", op->negate ? "(i32.eqz " : "",
                   int_left ? op->int_float : op->float_int, int_left ? ic->i : fc->f, int_left ? fc->f : ic->i,
                   op->negate ? ")" : "");
    }
}

/* A comparison involving an opaque operand, as `(block (result i32) …)`:
 * same-tag int or float compares inline, mixed int/float through the exact
 * mixed compare, and everything else through the generic helper +
 * $lua_truthy. */
static void emit_maybe_cmp_block(CG *c, const Expr *e, int depth) {
    const CmpOp *op = cmp_op(e->as.binop.op);
    MCell a, b;
    emit_line(c, depth, "(block (result i32)\n");
    int k = emit_maybe_operands(c, e->as.binop.lhs, e->as.binop.rhs, &a, &b, depth + 1);
    emit_line(c, depth + 1, "(if (result i32)\n");
    emit_both_tags(c, &a, &b, 1, depth + 2);
    emit_linef(c, depth + 2, "(then (%s %s %s))\n", op->i64, a.i, b.i);
    emit_line(c, depth + 2, "(else (if (result i32)\n");
    emit_both_tags(c, &a, &b, 2, depth + 3);
    emit_linef(c, depth + 3, "(then (%s %s %s))\n", op->f64, a.f, b.f);
    /* Both numeric with different tags: int vs float. A side whose tag is
     * static decides which way round; otherwise test at run time. */
    int at = mcell_static_tag(&a), bt = mcell_static_tag(&b);
    int mixed = !(at && bt && at == bt);
    if (mixed) {
        emit_linef(c, depth + 3, "(else (if (result i32) (i32.and (i32.ne %s (i32.const 0)) (i32.ne %s (i32.const 0)))\n",
                   a.t, b.t);
        emit_line(c, depth + 4, "(then\n");
        if (at == 1 || bt == 2) {
            emit_mixed_cell_cmp(c, op, e, &a, &b, 1, depth + 5);
        } else if (at == 2 || bt == 1) {
            emit_mixed_cell_cmp(c, op, e, &a, &b, 0, depth + 5);
        } else {
            emit_linef(c, depth + 5, "(if (result i32) (i32.eq %s (i32.const 1))\n", a.t);
            emit_line(c, depth + 6, "(then\n");
            emit_mixed_cell_cmp(c, op, e, &a, &b, 1, depth + 7);
            emit_line(c, depth + 6, ")\n");
            emit_line(c, depth + 6, "(else\n");
            emit_mixed_cell_cmp(c, op, e, &a, &b, 0, depth + 7);
            emit_line(c, depth + 6, "))\n");
        }
        emit_line(c, depth + 4, ")\n");
    }
    emit_linef(c, depth + 3 + mixed, "(else (call $lua_truthy (call %s\n", binop_helper(e->as.binop.op));
    emit_maybe_cell_box(c, &a, depth + 4 + mixed);
    emit_maybe_cell_box(c, &b, depth + 4 + mixed);
    emit_line(c, depth + 3 + mixed, mixed ? "))))))))\n" /* call, call, else, if(mixed), else, if, else, if */
                                          : "))))))\n"); /* call, call, else, if, else, if */
    emit_line(c, depth, ")\n");
    c->mt_depth = k;
}

/* Mark the local slots an assignment statement stores to. */
typedef struct {
    unsigned char *reassigned;
    int n;
} Reassigned;
static void mark_reassigned_visit(const Stmt *s, void *ctx) {
    Reassigned *r = ctx;
    if (s->kind != STMT_ASSIGN) return;
    for (int j = 0; j < s->as.assign.n_targets; j++) {
        const AssignTarget *t = &s->as.assign.targets[j];
        if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL && t->as.var.idx >= 0 && t->as.var.idx < r->n)
            r->reassigned[t->as.var.idx] = 1;
    }
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
    const LuaFunc **slot_func;  /* [n_locals]  slot -> bound LuaFunc (or NULL) */
    unsigned char *reass_local; /* [n_locals]  slot assigned somewhere in body */
    unsigned char *reass_upval; /* [n_upvalues] upvalue assigned in body (or NULL) */
    int n_locals, n_upvalues;
} BindAccum;

static void bind_visit(const Stmt *s, void *ctx) {
    BindAccum *a = ctx;
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
            else if (t->as.var.kind == VAR_UPVAL && a->reass_upval && t->as.var.idx >= 0 && t->as.var.idx < a->n_upvalues)
                a->reass_upval[t->as.var.idx] = 1;
        }
        break;
    default: break; /* nested function literals are walked on their own row */
    }
}

/* The slot_func map (and its length) for a given enclosing scope; func_idx == -1
 * is the main chunk. */
static const LuaFunc **bind_slot_map(CG *c, int func_idx, int *n_out) {
    if (func_idx == -1) {
        *n_out = c->pr->main_n_locals;
        return c->main_slot_func;
    }
    if (func_idx < 0 || func_idx >= c->n_sigs) {
        *n_out = 0;
        return NULL;
    }
    *n_out = c->pr->funcs.items[func_idx]->n_locals;
    return c->bind_slot[func_idx];
}

/* Trace upvalue u of function func_idx back to the (scope, local-slot) where it
 * originates. *of == -1 means the main chunk; *of == -2 means unresolvable. */
static void resolve_upval_origin(CG *c, int func_idx, int u, int *of, int *os) {
    const LuaFunc *F = c->pr->funcs.items[func_idx];
    if (!F->upvalues || u < 0 || u >= F->n_upvalues) {
        *of = -2;
        *os = -1;
        return;
    }
    UpvalueRef ref = F->upvalues[u];
    if (ref.src == UPVAL_FROM_LOCAL) {
        *of = F->parent_idx;
        *os = ref.idx;
    } else if (F->parent_idx >= 0) resolve_upval_origin(c, F->parent_idx, ref.idx, of, os);
    else {
        *of = -2;
        *os = -1;
    } /* main has no upvalues */
}

/* Build c->bind_slot / c->bind_upval / c->main_slot_func. */
static void compute_func_bindings(CG *c, const ParseResult *pr) {
    int n = (int)pr->funcs.count;
    c->n_binds = n; /* free_func_bindings frees exactly this many rows */
    c->bind_slot = calloc(n ? n : 1, sizeof *c->bind_slot);
    c->bind_upval = calloc(n ? n : 1, sizeof *c->bind_upval);
    c->main_slot_func = calloc(pr->main_n_locals ? pr->main_n_locals : 1, sizeof(const LuaFunc *));
    unsigned char **reass_upval = calloc(n ? n : 1, sizeof *reass_upval);

    /* Pass 1: per-scope bindings; drop directly-reassigned local bindings. */
    {
        unsigned char *rl = calloc(pr->main_n_locals ? pr->main_n_locals : 1, 1);
        BindAccum a = {c->main_slot_func, rl, NULL, pr->main_n_locals, 0};
        walk_stmts(&pr->main_body, bind_visit, &a);
        for (int s = 0; s < pr->main_n_locals; s++)
            if (rl[s]) c->main_slot_func[s] = NULL;
        free(rl);
    }
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        c->bind_slot[f] = calloc(F->n_locals ? F->n_locals : 1, sizeof(const LuaFunc *));
        c->bind_upval[f] = calloc(F->n_upvalues ? F->n_upvalues : 1, sizeof(const LuaFunc *));
        reass_upval[f] = calloc(F->n_upvalues ? F->n_upvalues : 1, 1);
        unsigned char *rl = calloc(F->n_locals ? F->n_locals : 1, 1);
        BindAccum a = {c->bind_slot[f], rl, reass_upval[f], F->n_locals, F->n_upvalues};
        walk_stmts(&F->body, bind_visit, &a);
        for (int s = 0; s < F->n_locals; s++)
            if (rl[s]) c->bind_slot[f][s] = NULL;
        free(rl);
    }

    /* Pass 2: a slot reassigned through an upvalue in any descendant is unstable
     * at its origin too. */
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        for (int u = 0; u < F->n_upvalues; u++) {
            if (!reass_upval[f][u]) continue;
            int of, os;
            resolve_upval_origin(c, f, u, &of, &os);
            int nn;
            const LuaFunc **m = bind_slot_map(c, of, &nn);
            if (m && os >= 0 && os < nn) m[os] = NULL;
        }
    }

    /* Pass 3: resolve each upvalue to its (now-finalized) bound function. */
    for (int f = 0; f < n; f++) {
        const LuaFunc *F = pr->funcs.items[f];
        for (int u = 0; u < F->n_upvalues; u++) {
            int of, os;
            resolve_upval_origin(c, f, u, &of, &os);
            int nn;
            const LuaFunc **m = bind_slot_map(c, of, &nn);
            c->bind_upval[f][u] = (m && os >= 0 && os < nn) ? m[os] : NULL;
        }
        free(reass_upval[f]);
    }
    free(reass_upval);
}

static void free_func_bindings(CG *c) {
    if (c->bind_slot)
        for (int i = 0; i < c->n_binds; i++) free((void *)c->bind_slot[i]);
    if (c->bind_upval)
        for (int i = 0; i < c->n_binds; i++) free((void *)c->bind_upval[i]);
    free(c->bind_slot);
    c->bind_slot = NULL;
    free(c->bind_upval);
    c->bind_upval = NULL;
    free(c->main_slot_func);
    c->main_slot_func = NULL;
    c->n_binds = 0;
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
    return a == b ? a : NT_ANY; /* INT vs FLOAT (or any disagreement) -> ANY */
}

/* Does every path through the block end in a `return`? Conservative: only the
 * trailing statement is examined (an if/else both of whose arms always return,
 * a do-block, or a literal return). */
static int block_always_returns(const Block *b);
static int stmt_always_returns(const Stmt *s) {
    switch (s->kind) {
    case STMT_RETURN: return 1;
    case STMT_DO: return block_always_returns(&s->as.do_stmt.body);
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
typedef struct {
    CG *c;
    NumTy acc;
} RetScan;
static void ret_scan_visit(const Stmt *s, void *ctx) {
    RetScan *r = ctx;
    if (s->kind != STMT_RETURN) return;
    r->acc = num_meet(r->acc, s->as.return_stmt.n_values == 1 ? expr_num_ty(r->c, s->as.return_stmt.values[0])
                                                              : NT_ANY);
}

/* Single-value return type of fn in the current context, or NT_ANY when the
 * function may fall through (return nil) or its returns aren't one shared
 * numeric type. */
static NumTy compute_ret_ty(CG *c, const LuaFunc *fn) {
    if (!block_always_returns(&fn->body)) return NT_ANY;
    RetScan r = {c, NT_UNSET};
    walk_stmts(&fn->body, ret_scan_visit, &r);
    return r.acc == NT_UNSET ? NT_ANY : r.acc; /* UNSET only if no returns at all */
}

/* Walk a body in the current context and, at each direct-call site, narrow the
 * callee's parameter types by meeting them with the argument types here. */
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
                if (nw != sg->param_ty[i]) {
                    sg->param_ty[i] = nw;
                    *changed = 1;
                }
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
typedef struct {
    CG *c;
    int *changed;
} SiteInfer;
static void infer_sites_visit(const Expr *e, void *ctx) {
    SiteInfer *si = ctx;
    infer_sites_expr(si->c, e, si->changed);
}
static void infer_sites_block(CG *c, const Block *b, int *changed) {
    walk_block_exprs(b, infer_sites_visit, &(SiteInfer){c, changed});
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
        if (r != c->sigs[fn->func_idx].ret_ty) {
            c->sigs[fn->func_idx].ret_ty = r;
            *changed = 1;
        }
    }

    c->cur_is_int = p_int;
    c->cur_is_float = p_float;
    c->cur_func_slot = p_fs;
    c->cur_upval_func = p_uv;
    c->cur_n_locals = p_nl;
    c->cur_n_params = p_np;
    c->cur_func_idx = p_fi;
    free(isint);
    free(isfloat);
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
        sg->ret_ty = NT_INT; /* optimistic; narrows downward */
        sg->has_site = 0;
        sg->param_ty = fn->n_params ? calloc(fn->n_params, sizeof(NumTy)) : NULL;
        /* A parameter is eligible for unboxing only if it is never reassigned
         * and never captured; others are pinned to NT_ANY. */
        int nl = fn->n_locals;
        unsigned char *reassigned = calloc(nl ? nl : 1, 1);
        walk_stmts(&fn->body, mark_reassigned_visit, &(Reassigned){reassigned, nl});
        for (int p = 0; p < fn->n_params; p++) {
            int pinned = reassigned[p] || (fn->captured && fn->captured[p]);
            sg->param_ty[p] = pinned ? NT_ANY : NT_UNSET; /* narrowed by sites */
        }
        free(reassigned);
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
        emit_line(c, depth, "(call $make_int\n");
        emit_int_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    if (c->opt_int && e->kind != EXPR_FLOAT && expr_is_float(c, e)) {
        emit_line(c, depth, "(call $make_float\n");
        emit_float_expr(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        return;
    }
    switch (e->kind) {
    case EXPR_NIL:
        emit_line(c, depth, "(ref.null any)\n");
        break;
    case EXPR_TRUE:
        emit_line(c, depth, "(global.get $g_true)\n");
        break;
    case EXPR_FALSE:
        emit_line(c, depth, "(global.get $g_false)\n");
        break;
    case EXPR_INT: emit_int_literal(c, e->as.i_val, depth); break;
    case EXPR_FLOAT: emit_float_literal(c, e->as.f_val, depth); break;
    case EXPR_STRING: emit_string_literal(c, e->as.s.bytes, e->as.s.len, depth); break;
    case EXPR_VAR: emit_var_read(c, e->as.var.kind, e->as.var.idx, depth); break;
    case EXPR_CALL: emit_call(c, e, depth); break;
    case EXPR_BINOP: emit_binop(c, e, depth); break;
    case EXPR_UNOP: emit_unop(c, e, depth); break;
    case EXPR_FUNCTION: emit_function_expr(c, e->as.func_expr.func, depth); break;
    case EXPR_INDEX: emit_index_expr(c, e, depth); break;
    case EXPR_TABLE: emit_table_ctor(c, e, depth); break;
    case EXPR_METHOD_CALL: {
        /* Single-value context: the fast entry when the call fits it, else
         * the full call wrapped in $args_first. */
        if (fast_call_nargs(c, e) >= 0) {
            emit_fast_call(c, e, depth);
            break;
        }
        emit_line(c, depth, "(call $args_first\n");
        emit_call_array(c, e, depth + 1);
        emit_line(c, depth, ")\n");
        break;
    }
    case EXPR_VARARG:
        emit_line(c, depth, "(call $args_first (local.get $varargs))\n");
        break;
    }
}

/* Emit `(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const idx))`
 * as a standalone indented line — the i-th value of the call/vararg result
 * currently parked in $tmp_args. */
static void emit_args_at(CG *c, int idx, int depth) {
    emit_linef(c, depth, "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const %d))\n",
               idx);
}

/* ----- statement arms (split out of emit_stmt) ----- */

/* Whether a stored value is worth lowering into a cell, so that a float
 * result can go to a table's unboxed float storage: a provable float, an
 * arithmetic tree over an opaque operand, a maybe slot, or an inline math
 * call. A bare table read or ordinary call is a boxed value already — passing
 * it through the plain store is cheaper than classifying and re-boxing it. */
static int store_value_lowers(CG *c, const Expr *v) {
    if (expr_is_float(c, v)) return 1;
    switch (v->kind) {
    case EXPR_BINOP:
    case EXPR_UNOP: return expr_involves_maybe(c, v);
    case EXPR_VAR: return v->as.var.kind == VAR_LOCAL && slot_is_maybe(c, v->as.var.idx);
    case EXPR_CALL:
        return v->as.call.nargs == 1 && !is_multival_tail(v->as.call.args[0]) &&
               callee_math_kind(c, v->as.call.callee) != MB_NONE;
    default: return 0;
    }
}

/* Lower a store's value into cell `vc`: a provable float straight into the f64
 * part, anything else through the maybe lowering. */
static void emit_store_value_cell(CG *c, const Expr *v, const MCell *vc, int depth) {
    if (expr_is_float(c, v)) {
        emit_linef(c, depth, "(local.set %s\n", vc->sf);
        emit_float_expr(c, v, depth + 1);
        emit_line(c, depth, ")\n");
        emit_set_tag(c, vc, 2, depth);
    } else {
        emit_maybe_lower(c, v, vc, depth);
    }
}

/* How an index store's key is held: a constant string (the hoisted global
 * `kb`), an i64 (kc.i), a maybe cell (kc), or a boxed value (kc.b). */
enum { SK_STR,
       SK_INT,
       SK_MAYBE,
       SK_ANY };

/* The store `tb[key] = value` with the table, key and value already
 * evaluated. A lowered value (vc a cell) that is a float goes to the unboxed
 * `_f` setter when the key allows it, else the value is boxed; a plain value
 * (`vb`, a boxed expression) takes the boxed setter. Every setter still
 * dispatches __newindex. */
static void emit_index_store_from(CG *c, const char *tb, int kkind, const char *kb, const MCell *kc,
                                  const MCell *vc, const char *vb, int depth) {
    char box[256], icb[48];
    if (vc) snprintf(box, sizeof box, "(call $box_num %s %s %s %s)", vc->t, vc->i, vc->f, vc->b);
    else snprintf(box, sizeof box, "%s", vb);
    /* a constant-key store goes through one inline cache for both forms */
    const char *ic = kkind == SK_STR ? ic_new(c, icb, sizeof icb) : NULL;
    emit_indent(c, depth);
    if (vc && kkind != SK_ANY) {
        if (kkind == SK_MAYBE)
            wat_appendf(c->w, "(if (i32.and (i32.eq %s (i32.const 2)) (i32.eq %s (i32.const 1)))\n", vc->t, kc->t);
        else wat_appendf(c->w, "(if (i32.eq %s (i32.const 2))\n", vc->t);
        emit_indent(c, depth + 1);
        if (kkind == SK_STR && ic) wat_appendf(c->w, "(then (call $lua_tabset_ic_f %s %s %s %s))\n", ic, tb, kb, vc->f);
        else if (kkind == SK_STR) wat_appendf(c->w, "(then (call $lua_tabset_sk_f %s %s %s))\n", tb, kb, vc->f);
        else wat_appendf(c->w, "(then (call $lua_tabset_ik_f %s %s %s))\n", tb, kc->i, vc->f);
        emit_line(c, depth + 1, "(else ");
        depth = 0; /* the boxed store below continues this line */
    }
    switch (kkind) {
    case SK_STR:
        if (ic) wat_appendf(c->w, "(call $lua_tabset_ic %s %s %s %s)", ic, tb, kb, box);
        else wat_appendf(c->w, "(call $lua_tabset_sk %s %s %s)", tb, kb, box);
        break;
    case SK_INT: wat_appendf(c->w, "(call $lua_tabset_ik %s %s %s)", tb, kc->i, box); break;
    case SK_MAYBE:
        wat_appendf(c->w, "(call $lua_tabset_mk %s %s %s %s %s %s)", tb, kc->t, kc->i, kc->f, kc->b, box);
        break;
    default: wat_appendf(c->w, "(call $lua_tabset %s %s %s)", tb, kc->b, box); break;
    }
    wat_append(c->w, vc && kkind != SK_ANY ? "))\n" : "\n");
}

/* `t[k] = v` where v is a lowered tree or a provably float expression and k
 * is a constant string, an int-typed expression or a maybe slot: evaluate
 * the table (Lua order: table, key, value), lower the value into a cell, and
 * store an f64 straight into the table's unboxed float storage when the
 * result is a float — no $LuaFloat allocation — else the boxed store.
 * Returns 0 (nothing emitted) when the shape doesn't qualify. */
static int emit_unboxed_index_store(CG *c, const AssignTarget *t, const Expr *v, int depth) {
    if (!c->opt_int || !c->cur_is_maybe) return 0;
    const Expr *key = t->as.index.key;
    int kstr = key->kind == EXPR_STRING && key->as.s.len <= KSTR_MAX;
    int kint = !kstr && expr_is_int(c, key);
    int kmaybe = !kstr && !kint && key->kind == EXPR_VAR && key->as.var.kind == VAR_LOCAL &&
                 slot_is_maybe(c, key->as.var.idx);
    if (!(kstr || kint || kmaybe)) return 0;
    if (!store_value_lowers(c, v)) return 0;
    int k = mt_alloc(c, 2);
    MCell tc = mcell_tmp(k), vc = mcell_tmp(k + 1);
    emit_linef(c, depth, "(local.set %s\n", tc.sb);
    emit_expr(c, t->as.index.table, depth + 1);
    emit_line(c, depth, ")\n");
    if (kint) { /* the key is evaluated once, before the value */
        emit_linef(c, depth, "(local.set %s\n", tc.si);
        emit_int_expr(c, key, depth + 1);
        emit_line(c, depth, ")\n");
    }
    emit_store_value_cell(c, v, &vc, depth);
    char kb[160] = "";
    if (kstr) kstr_expr(c, key->as.s.bytes, key->as.s.len, kb, sizeof kb);
    MCell kc = kmaybe ? mcell_slot(key->as.var.idx) : tc;
    emit_index_store_from(c, tc.b, kstr ? SK_STR : kint ? SK_INT
                                                        : SK_MAYBE,
                          kb, &kc, &vc, NULL, depth);
    c->mt_depth = k;
    return 1;
}

/* Multi-assignment `t1[k1], x, t2[k2] = v1, v2, v3` with one value per target,
 * through lowering temporaries instead of the $ArgArr path: every target's
 * table and key is evaluated (left to right) into a cell, then every value —
 * lowered when it can yield an unboxed float — and finally the stores run
 * right to left (so a repeated target keeps its leftmost value, as in
 * reference Lua). Keys are snapshotted, so `t[i], i = 1, 2` indexes with the
 * old i. Index stores take the same constant-string / int / maybe-key and
 * unboxed-float setters as a single store. Returns 0 when not applicable. */
static int emit_assign_multi_cells(CG *c, const Stmt *s, int depth) {
    int nt = s->as.assign.n_targets;
    if (!c->opt_int || nt < 2 || s->as.assign.n_values != nt) return 0;
    for (int i = 0; i < nt; i++) {
        const AssignTarget *t = &s->as.assign.targets[i];
        if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL && slot_is_maybe(c, t->as.var.idx)) return 0;
    }
    int k0 = c->mt_depth;
    /* per target: table, key and value cells, key kind, value lowered?, key string */
    struct {
        MCell t, k, v;
        int kkind, lowered;
        char kb[160];
    } *g = xmalloc((size_t)nt * sizeof *g);
    for (int i = 0; i < nt; i++) {
        const AssignTarget *t = &s->as.assign.targets[i];
        g[i].kb[0] = '\0';
        if (t->kind == TGT_VAR) continue;
        const Expr *key = t->as.index.key;
        g[i].t = mcell_tmp(mt_alloc(c, 1));
        emit_linef(c, depth, "(local.set %s\n", g[i].t.sb);
        emit_expr(c, t->as.index.table, depth + 1);
        emit_line(c, depth, ")\n");
        if (key->kind == EXPR_STRING && key->as.s.len <= KSTR_MAX) {
            g[i].kkind = SK_STR;
            kstr_expr(c, key->as.s.bytes, key->as.s.len, g[i].kb, sizeof g[i].kb);
            continue;
        }
        g[i].k = mcell_tmp(mt_alloc(c, 1));
        if (expr_is_int(c, key)) {
            g[i].kkind = SK_INT;
            emit_linef(c, depth, "(local.set %s\n", g[i].k.si);
            emit_int_expr(c, key, depth + 1);
            emit_line(c, depth, ")\n");
        } else if (key->kind == EXPR_VAR && key->as.var.kind == VAR_LOCAL && slot_is_maybe(c, key->as.var.idx)) {
            g[i].kkind = SK_MAYBE;
            MCell ks = mcell_slot(key->as.var.idx);
            emit_linef(c, depth, "(local.set %s %s) (local.set %s %s) (local.set %s %s) (local.set %s %s)\n",
                       g[i].k.st, ks.t, g[i].k.si, ks.i, g[i].k.sf, ks.f, g[i].k.sb, ks.b);
        } else {
            g[i].kkind = SK_ANY;
            emit_linef(c, depth, "(local.set %s\n", g[i].k.sb);
            emit_expr(c, key, depth + 1);
            emit_line(c, depth, ")\n");
        }
    }
    for (int i = 0; i < nt; i++) {
        const Expr *v = s->as.assign.values[i];
        g[i].v = mcell_tmp(mt_alloc(c, 1));
        g[i].lowered = s->as.assign.targets[i].kind == TGT_INDEX && store_value_lowers(c, v);
        if (g[i].lowered) {
            emit_store_value_cell(c, v, &g[i].v, depth);
        } else {
            emit_linef(c, depth, "(local.set %s\n", g[i].v.sb);
            emit_expr(c, v, depth + 1);
            emit_line(c, depth, ")\n");
        }
    }
    for (int i = nt - 1; i >= 0; i--) {
        const AssignTarget *t = &s->as.assign.targets[i];
        if (t->kind == TGT_VAR) {
            emit_target_open(c, t, depth);
            emit_linef(c, depth + 1, "%s\n", g[i].v.b);
            emit_target_close(c, depth);
        } else {
            emit_index_store_from(c, g[i].t.b, g[i].kkind, g[i].kb, &g[i].k, g[i].lowered ? &g[i].v : NULL,
                                  g[i].v.b, depth);
        }
    }
    free(g);
    c->mt_depth = k0;
    return 1;
}

static void emit_assign(CG *c, const Stmt *s, int depth) {
    int n_targets = s->as.assign.n_targets;
    int n_values = s->as.assign.n_values;
    /* Fast path only for exactly one target and one value. With a longer
     * value list (`a = 5, g()`) the extra values must still be evaluated
     * left-to-right for their side effects; fall through to the general
     * path, which builds the full value array and stores target[0] from
     * it. */
    if (n_targets == 1 && n_values == 1) {
        AssignTarget *t = &s->as.assign.targets[0];
        if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL && slot_is_int(c, t->as.var.idx)) {
            emit_linef(c, depth, "(local.set $L%d\n", t->as.var.idx);
            emit_int_expr(c, s->as.assign.values[0], depth + 1);
            emit_line(c, depth, ")\n");
            return;
        }
        if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL && slot_is_float(c, t->as.var.idx)) {
            emit_linef(c, depth, "(local.set $L%d\n", t->as.var.idx);
            emit_float_expr(c, s->as.assign.values[0], depth + 1);
            emit_line(c, depth, ")\n");
            return;
        }
        if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL && slot_is_maybe(c, t->as.var.idx)) {
            emit_maybe_store(c, t->as.var.idx, s->as.assign.values[0], depth);
            return;
        }
        if (t->kind == TGT_INDEX && emit_unboxed_index_store(c, t, s->as.assign.values[0], depth)) return;
        /* A lone call / `...` value supplies its first value (emit_expr takes
         * the call's single-value entry). */
        emit_target_open(c, t, depth);
        emit_expr(c, s->as.assign.values[0], depth + 1);
        emit_target_close(c, depth);
        return;
    }
    if (emit_assign_multi_cells(c, s, depth)) return;
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
     * target is a variable. (last_call is only relevant to the
     * single-target branch above; the multi-target path always
     * builds the full $tmp_args array via emit_args_array.) */
    /* An index target whose table and key are non-captured locals (or the
     * key a literal) has a static address too: evaluating the values first
     * can't change it, and neither can an earlier store's __newindex (locals
     * are unreachable from metamethods unless captured). Such targets store
     * through emit_target_open like single stores — keeping the int / maybe /
     * constant-key fast paths (`q[i], q[j] = q[j], q[i]`). */
    int has_index = 0;
    for (int i = 0; i < n_targets; i++) {
        AssignTarget *t = &s->as.assign.targets[i];
        if (t->kind == TGT_VAR) continue;
        const Expr *tb = t->as.index.table, *k = t->as.index.key;
        int tb_static = tb->kind == EXPR_VAR && tb->as.var.kind == VAR_LOCAL && !slot_is_boxed(c, tb->as.var.idx);
        int k_static = k->kind == EXPR_INT || k->kind == EXPR_FLOAT || k->kind == EXPR_STRING ||
                       (k->kind == EXPR_VAR && k->as.var.kind == VAR_LOCAL && !slot_is_boxed(c, k->as.var.idx));
        if (!(tb_static && k_static)) {
            has_index = 1;
            break;
        }
    }
    if (has_index) {
        emit_linef(c, depth, "(local.set $tmp_lhs_t (array.new $ArgArr (ref.null any) "
                             "(i32.const %d)))\n",
                   n_targets);
        emit_linef(c, depth, "(local.set $tmp_lhs_k (array.new $ArgArr (ref.null any) "
                             "(i32.const %d)))\n",
                   n_targets);
        for (int i = 0; i < n_targets; i++) {
            AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind == TGT_VAR) continue;
            emit_linef(c, depth, "(array.set $ArgArr (ref.as_non_null (local.get $tmp_lhs_t)) "
                                 "(i32.const %d)\n",
                       i);
            emit_expr(c, t->as.index.table, depth + 1);
            emit_line(c, depth, ")\n");
            emit_linef(c, depth, "(array.set $ArgArr (ref.as_non_null (local.get $tmp_lhs_k)) "
                                 "(i32.const %d)\n",
                       i);
            emit_expr(c, t->as.index.key, depth + 1);
            emit_line(c, depth, ")\n");
        }
    }
    emit_line(c, depth, "(local.set $tmp_args\n");
    emit_args_array(c, s->as.assign.values, n_values, depth + 1);
    emit_line(c, depth, ")\n");
    for (int i = n_targets - 1; i >= 0; i--) {
        AssignTarget *t = &s->as.assign.targets[i];
        if (t->kind == TGT_VAR || !has_index) {
            emit_target_open(c, t, depth);
            emit_args_at(c, i, depth + 1);
            emit_target_close(c, depth);
        } else {
            /* index target: store via pre-evaluated table+key so
             * __newindex still fires (matches emit_target_open). */
            emit_line(c, depth, "(call $lua_tabset\n");
            emit_linef(c, depth + 1, "(array.get $ArgArr (ref.as_non_null (local.get $tmp_lhs_t)) "
                                     "(i32.const %d))\n",
                       i);
            emit_linef(c, depth + 1, "(array.get $ArgArr (ref.as_non_null (local.get $tmp_lhs_k)) "
                                     "(i32.const %d))\n",
                       i);
            emit_args_at(c, i, depth + 1);
            emit_line(c, depth, ")\n");
        }
    }
}

/* Does the body being emitted return exactly one value ($user_N_da1 or
 * $user_N_f) rather than a result array? */
static int entry_single_result(const CG *c) { return c->entry == ENTRY_DIRECT1 || c->entry == ENTRY_FAST; }

static void emit_return(CG *c, const Stmt *s, int depth) {
    int n_values = s->as.return_stmt.n_values;
    /* Close-aware return: any to-be-closed local in scope must be closed
     * before the function returns. Evaluate the result onto the stack first
     * ($close_upto is stack-neutral, so it stays beneath), then close the whole
     * to-be-closed stack (down to 0), then return. A `return f()` here is NOT a
     * tail call — the locals must close after f() returns. */
    if (c->close_count > 0) {
        if (c->in_main) {
            for (int i = 0; i < n_values; i++) {
                emit_expr(c, s->as.return_stmt.values[i], depth);
                emit_line(c, depth, "drop\n");
            }
            emit_close_upto(c, 0, "(ref.null any)", depth);
            emit_line(c, depth, "return\n");
            return;
        }
        if (entry_single_result(c)) {
            if ((c->cur_ret_ty == NT_INT || c->cur_ret_ty == NT_FLOAT) && n_values == 1) {
                if (c->cur_ret_ty == NT_INT)
                    emit_int_expr(c, s->as.return_stmt.values[0], depth);
                else
                    emit_num_as_f64(c, s->as.return_stmt.values[0], depth);
            } else if (n_values == 0) {
                emit_line(c, depth, "(ref.null any)\n");
            } else {
                emit_expr(c, s->as.return_stmt.values[0], depth);
                for (int i = 1; i < n_values; i++) {
                    emit_expr(c, s->as.return_stmt.values[i], depth);
                    emit_line(c, depth, "drop\n");
                }
            }
        } else if (n_values == 1 && is_multival_tail(s->as.return_stmt.values[0])) {
            emit_multival_array(c, s->as.return_stmt.values[0], depth);
        } else {
            emit_args_array(c, s->as.return_stmt.values, n_values, depth);
        }
        emit_close_upto(c, 0, "(ref.null any)", depth);
        emit_line(c, depth, "return\n");
        return;
    }
    if (c->in_main) {
        /* $main is exported with no result, so the chunk's return
         * value can't be surfaced to the host — but we still have
         * to evaluate the expressions so their side effects fire
         * (e.g. `return print("hi")`). Drop each result after
         * evaluation, then exit. */
        for (int i = 0; i < n_values; i++) {
            emit_expr(c, s->as.return_stmt.values[i], depth);
            emit_line(c, depth, "drop\n");
        }
        emit_line(c, depth, "return\n");
        return;
    }
    if (c->entry == ENTRY_FAST && n_values == 1 && !s->as.return_stmt.values[0]->paren &&
        fast_call_nargs(c, s->as.return_stmt.values[0]) >= 0) {
        /* A $user_N_f body's tail call that fits the fast entry stays a
         * proper tail call; wider ones fall to the single-value code below
         * (an ordinary call — the callee's generic body keeps its own tail
         * calls proper, so the stack stays bounded). */
        emit_fast_tail_call(c, s->as.return_stmt.values[0], depth);
        return;
    }
    if (entry_single_result(c)) {
        /* Single-value-return entry ($user_N_da1): produce exactly one
         * value of the entry's result type. A numeric ret_ty was inferred
         * only when every return is a single numeric value, so emit it
         * raw (i64/f64). */
        if ((c->cur_ret_ty == NT_INT || c->cur_ret_ty == NT_FLOAT) && n_values == 1) {
            emit_line(c, depth, "(return\n");
            if (c->cur_ret_ty == NT_INT) emit_int_expr(c, s->as.return_stmt.values[0], depth + 1);
            else emit_num_as_f64(c, s->as.return_stmt.values[0], depth + 1);
            emit_line(c, depth, ")\n");
            return;
        }
        /* ret_ty == ANY: produce a single anyref. A non-vararg body never
         * uses `...`, so a lone multi-value tail here is a call, adjusted
         * to one by emit_expr. Extra return values still evaluate (side
         * effects), in order. */
        if (n_values == 0) {
            emit_line(c, depth, "(return (ref.null any))\n");
        } else if (n_values == 1) {
            emit_line(c, depth, "(return\n");
            emit_expr(c, s->as.return_stmt.values[0], depth + 1);
            emit_line(c, depth, ")\n");
        } else {
            emit_line(c, depth, "(local.set $tmp_any\n");
            emit_expr(c, s->as.return_stmt.values[0], depth + 1);
            emit_line(c, depth, ")\n");
            for (int i = 1; i < n_values; i++) {
                emit_expr(c, s->as.return_stmt.values[i], depth);
                emit_line(c, depth, "drop\n");
            }
            emit_line(c, depth, "(return (local.get $tmp_any))\n");
        }
        return;
    }
    /* Tail-call optimization: exactly `return f(args)` or
     * `return obj:m(args)` (not parenthesized, which forces adjust-to-
     * one and so isn't a tail call). */
    if (n_values == 1 && !s->as.return_stmt.values[0]->paren && (s->as.return_stmt.values[0]->kind == EXPR_CALL || s->as.return_stmt.values[0]->kind == EXPR_METHOD_CALL)) {
        emit_tail_call(c, s->as.return_stmt.values[0], depth);
        return;
    }
    /* `return f(), x, ...` and similar: build the result array. A lone
     * multi-value tail (a single call/vararg) returns its array as-is. */
    if (n_values == 1 && is_multival_tail(s->as.return_stmt.values[0])) {
        emit_multival_array(c, s->as.return_stmt.values[0], depth);
    } else {
        emit_args_array(c, s->as.return_stmt.values, n_values, depth);
    }
    emit_line(c, depth, "return\n");
}

static void emit_for_num(CG *c, const Stmt *s, int depth) {
    int label = c->next_label++;
    if (!push_break_label(c, label)) return;
    int slot = s->as.for_num.local_idx;
    /* Integer-specialized loop: control var + bounds are i64, the
     * counter is an unboxed i64 slot, no per-iteration boxing or
     * generic-helper calls. The analysis only marks the slot int when
     * start and step are integer and the var isn't captured; a limit that
     * isn't statically an integer is converted once by $for_limit. */
    if (slot_is_int(c, slot)) {
        int fd = c->for_depth;
        const Expr *st = s->as.for_num.step;
        int stop_int = expr_is_int(c, s->as.for_num.stop);
        char step_s[40];
        int sign; /* +1/-1 known at compile time; 0 = runtime */
        if (!st) {
            snprintf(step_s, sizeof step_s, "(i64.const 1)");
            sign = 1;
        } else if (st->kind == EXPR_INT && st->as.i_val != 0) {
            snprintf(step_s, sizeof step_s, "(i64.const %lld)", (long long)st->as.i_val);
            sign = st->as.i_val > 0 ? 1 : -1;
        } else {
            snprintf(step_s, sizeof step_s, "(local.get $ifor_step_%d)", fd);
            sign = 0;
        }
        emit_linef(c, depth, "(local.set $L%d\n", slot);
        emit_int_expr(c, s->as.for_num.start, depth + 1);
        emit_line(c, depth, ")\n");
        emit_indent(c, depth);
        if (stop_int) {
            wat_appendf(c->w, "(local.set $ifor_stop_%d\n", fd);
            emit_int_expr(c, s->as.for_num.stop, depth + 1);
        } else {
            wat_appendf(c->w, "(local.set $for_stop_%d\n", fd);
            emit_expr(c, s->as.for_num.stop, depth + 1);
        }
        emit_line(c, depth, ")\n");
        if (sign == 0) {
            emit_linef(c, depth, "(local.set $ifor_step_%d\n", fd);
            emit_int_expr(c, st, depth + 1);
            emit_line(c, depth, ")\n");
            emit_linef(c, depth, "(if (i64.eqz %s) (then (call $throw_lit_at (i32.const 75) (i32.const 18) (i32.const %d))))\n",
                       step_s, s->line);
        }
        if (!stop_int) {
            emit_linef(c, depth, "(call $for_limit (local.get $for_stop_%d) (local.get $L%d) %s (i32.const %d))\n", fd,
                       slot, step_s, s->line);
            emit_linef(c, depth, "(local.set $for_skip_%d)\n", fd);
            emit_linef(c, depth, "(local.set $ifor_stop_%d)\n", fd);
        }
        emit_linef(c, depth, "(block $brk_%d\n", label);
        if (!stop_int) {
            emit_linef(c, depth + 1, "(br_if $brk_%d (local.get $for_skip_%d))\n", label, fd);
        }
        emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
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
        emit_linef(c, depth + 2, "(local.set $ifor_next_%d (i64.add (local.get $L%d) %s))\n", fd, slot, step_s);
        emit_indent(c, depth + 2);
        if (sign == 1)
            wat_appendf(c->w, "(br_if $brk_%d (i64.lt_s (local.get $ifor_next_%d) (local.get $L%d)))\n", label, fd, slot);
        else if (sign == -1)
            wat_appendf(c->w, "(br_if $brk_%d (i64.gt_s (local.get $ifor_next_%d) (local.get $L%d)))\n", label, fd, slot);
        else
            wat_appendf(c->w,
                        "(if (i64.gt_s %s (i64.const 0)) (then (br_if $brk_%d (i64.lt_s (local.get $ifor_next_%d) (local.get $L%d)))) (else (br_if $brk_%d (i64.gt_s (local.get $ifor_next_%d) (local.get $L%d)))))\n",
                        step_s, label, fd, slot, label, fd, slot);
        emit_linef(c, depth + 2, "(local.set $L%d (local.get $ifor_next_%d))\n", slot, fd);
        emit_linef(c, depth + 2, "br $cont_%d\n", label);
        emit_line(c, depth + 1, ")\n");
        emit_line(c, depth, ")\n");
        c->break_depth--;
        return;
    }
    int boxed = slot_is_boxed(c, slot);
    /* Per-nesting-level scratch so an inner for-loop can't clobber
     * this loop's stop/step. */
    int fd = c->for_depth;
    char f_stop[24], f_step[24], f_next[24], f_cur[24];
    snprintf(f_stop, sizeof f_stop, "$for_stop_%d", fd);
    snprintf(f_step, sizeof f_step, "$for_step_%d", fd);
    snprintf(f_next, sizeof f_next, "$for_next_%d", fd);
    snprintf(f_cur, sizeof f_cur, "$for_cur_%d", fd);
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
    emit_line(c, depth, ")\n");
    emit_linef(c, depth, "(local.set %s\n", f_stop);
    emit_expr(c, s->as.for_num.stop, depth + 1);
    emit_line(c, depth, ")\n");
    emit_linef(c, depth, "(local.set %s\n", f_step);
    if (s->as.for_num.step) {
        emit_expr(c, s->as.for_num.step, depth + 1);
    } else {
        emit_line(c, depth + 1, "(ref.i31 (i32.const 1))\n");
    }
    emit_line(c, depth, ")\n");
    /* $for_prep applies Lua's forprep: it settles the loop's type (integer
     * iff init and step are integers, else all three coerced to floats),
     * converts the limit, raises on a zero step or a non-numeric value, and
     * says whether the loop runs at all. counter_loc is the local that holds
     * the running value. */
    char counter_loc[24];
    if (boxed) snprintf(counter_loc, sizeof counter_loc, "%s", f_cur);
    else snprintf(counter_loc, sizeof counter_loc, "$L%d", slot);
    char f_skip[24];
    snprintf(f_skip, sizeof f_skip, "$for_skip_%d", fd);
    emit_linef(c, depth, "(call $for_prep (local.get %s) (local.get %s) (local.get %s) (i32.const %d))\n",
               counter_loc, f_stop, f_step, s->line);
    emit_linef(c, depth, "(local.set %s) (local.set %s) (local.set %s) (local.set %s)\n", f_skip, f_step, f_stop,
               counter_loc);
    char load_buf[80];
    snprintf(load_buf, sizeof(load_buf), "(local.get %s)", counter_loc);

    emit_linef(c, depth, "(block $brk_%d\n", label);
    emit_linef(c, depth + 1, "(br_if $brk_%d (local.get %s))\n", label, f_skip);
    emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
    /* Fresh per-iteration binding for a captured control variable. */
    if (boxed) {
        emit_linef(c, depth + 2, "(local.set $L%d (struct.new $Box %s))\n", slot, load_buf);
    }
    /* body */
    c->for_depth++;
    emit_block(c, &s->as.for_num.body, depth + 2);
    c->for_depth--;
    /* i = i + step, but stop if the integer addition wrapped past the
     * representable range (Lua 5.4 numeric-for overflow semantics) —
     * otherwise `for i = maxinteger-2, maxinteger` would loop forever. */
    emit_linef(c, depth + 2, "(local.set %s (call $lua_add %s (local.get %s)))\n", f_next, load_buf, f_step);
    emit_linef(c, depth + 2, "(br_if $brk_%d (call $for_overflowed %s (local.get %s) (local.get %s)))\n", label, load_buf,
               f_step, f_next);
    emit_linef(c, depth + 2, "(local.set %s (local.get %s))\n", counter_loc, f_next);
    /* Continue while the new value is within the limit. The entry test was
     * $for_prep's, so only later iterations compare here (a NaN float bound
     * runs the body once, as in reference Lua). */
    emit_linef(c, depth + 2, "(if (call $for_step_positive (local.get %s))\n"
                             "%*s  (then (br_if $brk_%d (i32.eqz (call $num_le %s (local.get %s)))))\n"
                             "%*s  (else (br_if $brk_%d (i32.eqz (call $num_le (local.get %s) %s)))))\n",
               f_step, 2 * (depth + 2), "", label, load_buf, f_stop, 2 * (depth + 2), "", label, f_stop, load_buf);
    emit_linef(c, depth + 2, "br $cont_%d\n", label);
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
    c->break_depth--;
}

static void emit_for_gen(CG *c, const Stmt *s, int depth) {
    /* Generic for: `for v1[, v2, ...] in iter [, state [, init]] do body end`.
     * Evaluate the expr_list into ($for_iter_any, $for_state, $for_k),
     * then loop: call iter(state, k); if first result is nil, break;
     * otherwise bind v1..vN to results, set k = result[0]. */
    int label = c->next_label++;
    if (!push_break_label(c, label)) return;
    /* Per-nesting-level iterator state so an inner for-loop can't
     * clobber this loop's iterator/state/control key. ($tmp_args is
     * recomputed each iteration, so it stays function-shared.) */
    int fd = c->for_depth;
    char f_iter[24], f_state[24], f_k[24];
    snprintf(f_iter, sizeof f_iter, "$for_iter_%d", fd);
    snprintf(f_state, sizeof f_state, "$for_state_%d", fd);
    snprintf(f_k, sizeof f_k, "$for_k_%d", fd);
    int n_exprs = s->as.for_gen.n_exprs;
    emit_line(c, depth, "(local.set $tmp_args\n");
    emit_args_array(c, s->as.for_gen.exprs, n_exprs, depth + 1);
    emit_line(c, depth, ")\n");
    /* iter = args[0]; state = args[1]; k = args[2]. */
    emit_linef(c, depth, "(local.set %s "
                         "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0)))\n",
               f_iter);
    emit_linef(c, depth, "(local.set %s "
                         "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 1)))\n",
               f_state);
    emit_linef(c, depth, "(local.set %s "
                         "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 2)))\n",
               f_k);
    /* The explist's 4th value is a to-be-closed "closing" value (Lua §3.3.5):
     * validate+push it now (after push_break_label recorded the pre-closing
     * depth, so `break` closes it too); close it when the loop exits. nil/false
     * (e.g. the common pairs/ipairs case) are accepted and never closed. */
    int for_close = for_gen_has_closing(s);
    int pre_close_base = c->close_count;
    if (for_close) {
        emit_line(c, depth, "(call $tbc_push (ref.as_non_null (local.get $tbc)) "
                            "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                            "(i32.const 3)))\n");
        c->close_count++;
    }

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

    emit_linef(c, depth, "(block $brk_%d\n", label);
    emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
    /* Call iter(state, k). The iterator can be any callable (a
     * closure, or a table with __call) — go through $lua_call_any
     * so a wrong type produces a typed error instead of a trap. */
    emit_line(c, depth + 2, "(local.set $tmp_args\n");
    emit_line(c, depth + 3, "(call $lua_call_any\n");
    emit_linef(c, depth + 4, "(local.get %s)\n", f_iter);
    emit_linef(c, depth + 4, "(array.new_fixed $ArgArr 2 (local.get %s) (local.get %s))\n", f_state, f_k);
    emit_linef(c, depth + 4, "(i32.const %d)\n", s->line);
    emit_line(c, depth + 3, ")\n");
    emit_line(c, depth + 2, ")\n");
    /* terminate if results[0] is nil */
    emit_linef(c, depth + 2, "(br_if $brk_%d (ref.is_null "
                             "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0))))\n",
               label);
    /* update k to results[0] */
    emit_linef(c, depth + 2, "(local.set %s "
                             "(call $args_at (ref.as_non_null (local.get $tmp_args)) (i32.const 0)))\n",
               f_k);
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
                        "(i32.const %d))))\n",
                        li, i);
        } else {
            wat_appendf(c->w,
                        "(local.set $L%d "
                        "(call $args_at (ref.as_non_null (local.get $tmp_args)) "
                        "(i32.const %d)))\n",
                        li, i);
        }
    }
    /* body */
    c->for_depth++;
    emit_block(c, &s->as.for_gen.body, depth + 2);
    c->for_depth--;
    emit_linef(c, depth + 2, "br $cont_%d\n", label);
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
    /* Loop exited normally (iterator returned nil) — close the closing value.
     * break already closed it (down to pre_close_base) before branching here,
     * so this is a no-op on that path; an error/goto exit closed it via $tbc. */
    if (for_close) {
        emit_close_upto(c, pre_close_base, "(ref.null any)", depth);
        c->close_count = pre_close_base;
    }
    c->break_depth--;
}

/* ----- statements ----- */
static void emit_stmt(CG *c, const Stmt *s, int depth) {
    if (!c->ok) return;
    switch (s->kind) {
    case STMT_LOCAL: {
        int n_names = s->as.local.n_names;
        int n_values = s->as.local.n_values;
        /* A trailing call / `...` only spreads when names remain after it;
         * otherwise only its first value (or none) is used, so it is a
         * single value like the rest (`local x = f()` takes the call's
         * single-value entry). */
        int last_call = (n_values > 0 && n_names > n_values &&
                         is_multival_tail(s->as.local.values[n_values - 1]));
        /* Count of leading single-valued source expressions: everything but
         * a trailing multivalue tail. Lua evaluates the value list strictly
         * left-to-right, so these are emitted *before* the trailing tail. */
        int n_lead = last_call ? n_values - 1 : n_values;
        /* 1. Leading single values, in source order. A value with a matching
         *    name is assigned to its slot; an excess value is still evaluated
         *    for its side effects (e.g. an __index trigger) and dropped. */
        for (int i = 0; i < n_lead; i++) {
            if (i >= n_names) {
                emit_expr(c, s->as.local.values[i], depth);
                emit_line(c, depth, "drop\n");
                continue;
            }
            int slot = s->as.local.local_idxs[i];
            if (slot_is_int(c, slot)) {
                /* i64 slot: analysis guarantees a matching single int value. */
                emit_linef(c, depth, "(local.set $L%d\n", slot);
                emit_int_expr(c, s->as.local.values[i], depth + 1);
                emit_line(c, depth, ")\n");
                continue;
            }
            if (slot_is_float(c, slot)) {
                emit_linef(c, depth, "(local.set $L%d\n", slot);
                emit_float_expr(c, s->as.local.values[i], depth + 1);
                emit_line(c, depth, ")\n");
                continue;
            }
            if (slot_is_maybe(c, slot)) {
                emit_maybe_store(c, slot, s->as.local.values[i], depth);
                continue;
            }
            int boxed = slot_is_boxed(c, slot);
            emit_linef(c, depth, boxed ? "(local.set $L%d (struct.new $Box\n" : "(local.set $L%d\n",
                       slot);
            emit_expr(c, s->as.local.values[i], depth + 1);
            emit_line(c, depth, boxed ? "))\n" : ")\n");
        }
        /* 2. Trailing multivalue tail, evaluated *after* the leading values
         *    and spread across the remaining names (and evaluated even when
         *    no name consumes it). Spread slots are never int/float-
         *    specialized (the analysis only specializes single literal/int
         *    initializers), so the boxed/anyref path covers them. */
        if (last_call) {
            emit_line(c, depth, "(local.set $tmp_args\n");
            emit_multival_array(c, s->as.local.values[n_values - 1], depth + 1);
            emit_line(c, depth, ")\n");
            for (int i = n_lead; i < n_names; i++) {
                int slot = s->as.local.local_idxs[i];
                int boxed = slot_is_boxed(c, slot);
                emit_linef(c, depth, boxed ? "(local.set $L%d (struct.new $Box\n" : "(local.set $L%d\n",
                           slot);
                emit_args_at(c, i - n_lead, depth + 1);
                emit_line(c, depth, boxed ? "))\n" : ")\n");
            }
        } else {
            /* 3. No trailing tail: names past the value list get nil. */
            for (int i = n_lead; i < n_names; i++) {
                int slot = s->as.local.local_idxs[i];
                int boxed = slot_is_boxed(c, slot);
                emit_linef(c, depth, boxed ? "(local.set $L%d (struct.new $Box (ref.null "
                                             "any)))\n"
                                           : "(local.set $L%d (ref.null any))\n",
                           slot);
            }
        }
        /* <close> declarations: push each onto the per-activation to-be-closed
         * stack. $tbc_push validates closability at the declaration (matching
         * reference Lua: a truthy value with no __close is rejected here, not
         * at scope exit; nil/false are accepted and never closed). close_count
         * tracks the live depth for the enclosing block / break / goto / return
         * close targets. */
        if (s->as.local.attribs) {
            for (int i = 0; i < n_names; i++) {
                if (s->as.local.attribs[i] != 2) continue;
                int slot = s->as.local.local_idxs[i];
                emit_indent(c, depth);
                if (slot_is_boxed(c, slot))
                    wat_appendf(c->w,
                                "(call $tbc_push (ref.as_non_null (local.get $tbc)) "
                                "(struct.get $Box $v (local.get $L%d)))\n",
                                slot);
                else
                    wat_appendf(c->w,
                                "(call $tbc_push (ref.as_non_null (local.get $tbc)) "
                                "(local.get $L%d))\n",
                                slot);
                c->close_count++;
            }
        }
        break;
    }

    case STMT_ASSIGN:
        emit_assign(c, s, depth);
        break;

    case STMT_EXPR: {
        /* Call as statement: its results are dropped, so a direct call takes
         * the single-value entry and a dynamic one the fast entry when they
         * apply; otherwise get the result array and drop it. */
        const Expr *ce = s->as.expr_stmt.expr;
        const LuaFunc *dt = ce->kind == EXPR_CALL ? direct_call_target(c, ce) : NULL;
        if (dt && direct_args_typed_ok(c, ce, dt)) emit_typed_direct_call1(c, ce, dt, depth);
        else if (fast_call_nargs(c, ce) >= 0) emit_fast_call(c, ce, depth);
        else emit_call_array(c, ce, depth);
        emit_line(c, depth, "drop\n");
        break;
    }

    case STMT_DO:
        emit_block(c, &s->as.do_stmt.body, depth);
        break;

    case STMT_RETURN:
        emit_return(c, s, depth);
        break;

    case STMT_WHILE: {
        int label = c->next_label++;
        if (!push_break_label(c, label)) break;
        emit_linef(c, depth, "(block $brk_%d\n", label);
        emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
        emit_truthy(c, s->as.while_stmt.cond, depth + 2);
        emit_line(c, depth + 2, "i32.eqz\n");
        emit_linef(c, depth + 2, "br_if $brk_%d\n", label);
        emit_block(c, &s->as.while_stmt.body, depth + 2);
        emit_linef(c, depth + 2, "br $cont_%d\n", label);
        emit_line(c, depth + 1, ")\n");
        emit_line(c, depth, ")\n");
        c->break_depth--;
        break;
    }

    case STMT_REPEAT: {
        int label = c->next_label++;
        if (!push_break_label(c, label)) break;
        emit_linef(c, depth, "(block $brk_%d\n", label);
        emit_linef(c, depth + 1, "(loop $cont_%d\n", label);
        /* A <close> var declared in the body stays in scope for the until
         * condition and is closed AFTER it (Lua §3.3.5). Emit the body
         * statements directly (emit_block would close at the body's end),
         * evaluate the condition, then close the body's to-be-closed vars.
         * $close_upto is a stack-neutral folded call, so it can sit between the
         * condition's i32 result and the br_if that consumes it. */
        int rbase = c->close_count;
        emit_block_stmts(c, &s->as.repeat.body, depth + 2);
        emit_truthy(c, s->as.repeat.cond, depth + 2);
        emit_line(c, depth + 2, "i32.eqz\n");
        if (c->close_count > rbase)
            emit_close_upto(c, rbase, "(ref.null any)", depth + 2);
        c->close_count = rbase;
        emit_linef(c, depth + 2, "br_if $cont_%d\n", label);
        emit_line(c, depth + 1, ")\n");
        emit_line(c, depth, ")\n");
        c->break_depth--;
        break;
    }

    case STMT_BREAK: {
        if (c->break_depth == 0) {
            cg_error(c, "break outside loop");
            break;
        }
        int label = c->break_labels[c->break_depth - 1];
        /* Close to-be-closed locals declared inside this loop before leaving. */
        int base = c->break_close_count[c->break_depth - 1];
        if (c->close_count > base) emit_close_upto(c, base, "(ref.null any)", depth);
        emit_linef(c, depth, "br $brk_%d\n", label);
        break;
    }

    case STMT_GOTO: {
        /* Dispatch lowering: set the target block's $next, then re-enter
         * its dispatch loop. The local and label are function-scoped, so
         * this works from inside arbitrarily nested blocks/loops. Before
         * leaving, close any to-be-closed vars whose scope the jump exits
         * (down to the count live at the target label). */
        if (c->close_count > s->as.label.close_base)
            emit_close_upto(c, s->as.label.close_base, "(ref.null any)", depth);
        emit_linef(c, depth, "(local.set $next_%d (i32.const %d))\n",
                   s->as.label.block_dispatch_id, s->as.label.target_segment_idx);
        emit_linef(c, depth, "(br $dispatch_%d)\n", s->as.label.block_dispatch_id);
        break;
    }

    case STMT_LABEL:
        /* Wrappers are emitted by emit_block; the label statement
         * itself produces no code at its position. */
        break;

    case STMT_FOR_NUM:
        emit_for_num(c, s, depth);
        break;

    case STMT_FOR_GEN:
        emit_for_gen(c, s, depth);
        break;

    case STMT_GLOBAL: {
        int n_names = s->as.global_decl.n_names;
        int n_values = s->as.global_decl.n_values;
        if (n_values == 0) break;
        int last_call = (n_values > 0 &&
                         is_multival_tail(s->as.global_decl.values[n_values - 1]));
        int n_lead = last_call ? n_values - 1 : n_values;
        /* Same left-to-right evaluation contract as STMT_LOCAL: leading
         * single values first, then the trailing multivalue tail. The store
         * keys are constant strings (no side effects), so only the value
         * order matters. */
        for (int i = 0; i < n_lead; i++) {
            if (i >= n_names) {
                emit_expr(c, s->as.global_decl.values[i], depth);
                emit_line(c, depth, "drop\n");
                continue;
            }
            int gi = s->as.global_decl.global_idxs[i];
            emit_line(c, depth, "(call $tab_set (ref.as_non_null (global.get $g_globals))\n");
            emit_indent(c, depth + 1);
            emit_global_key(c, c->pr->globals.items[gi].name,
                            c->pr->globals.items[gi].name_len);
            emit_expr(c, s->as.global_decl.values[i], depth + 1);
            emit_line(c, depth, ")\n");
        }
        if (last_call) {
            emit_line(c, depth, "(local.set $tmp_args\n");
            emit_multival_array(c, s->as.global_decl.values[n_values - 1], depth + 1);
            emit_line(c, depth, ")\n");
        }
        for (int i = n_lead; i < n_names; i++) {
            int gi = s->as.global_decl.global_idxs[i];
            emit_line(c, depth, "(call $tab_set (ref.as_non_null (global.get $g_globals))\n");
            emit_indent(c, depth + 1);
            emit_global_key(c, c->pr->globals.items[gi].name,
                            c->pr->globals.items[gi].name_len);
            if (last_call) {
                emit_args_at(c, i - n_lead, depth + 1);
            } else {
                emit_line(c, depth + 1, "(ref.null any)\n");
            }
            emit_line(c, depth, ")\n");
        }
        break;
    }

    case STMT_IF: {
        int label = c->next_label++;
        emit_linef(c, depth, "(block $if_end_%d\n", label);
        for (size_t i = 0; i < s->as.if_stmt.narms; i++) {
            IfArm *a = &s->as.if_stmt.arms[i];
            emit_truthy(c, a->cond, depth + 1);
            emit_line(c, depth + 1, "(if (then\n");
            emit_block(c, &a->body, depth + 2);
            emit_linef(c, depth + 2, "br $if_end_%d\n", label);
            emit_line(c, depth + 1, "))\n");
        }
        if (s->as.if_stmt.has_else) {
            emit_block(c, &s->as.if_stmt.else_body, depth + 1);
        }
        emit_line(c, depth, ")\n");
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
            emit_linef(c, depth, "(local.set $L%d (struct.new $Box (ref.null any)))\n", slot);
            emit_line(c, depth, "(struct.set $Box $v\n");
            emit_linef(c, depth + 1, "(local.get $L%d)\n", slot);
            emit_function_expr(c, s->as.local_func.func, depth + 1);
            emit_line(c, depth, ")\n");
        } else {
            emit_linef(c, depth, "(local.set $L%d\n", slot);
            emit_function_expr(c, s->as.local_func.func, depth + 1);
            emit_line(c, depth, ")\n");
        }
        break;
    }
    }
}

/* Count <close> declarations at this block level (not in nested blocks). */
static int count_block_close(const Block *b) {
    int n = 0;
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *s = b->items[i];
        if (s->kind != STMT_LOCAL || !s->as.local.attribs) continue;
        for (int j = 0; j < s->as.local.n_names; j++)
            if (s->as.local.attribs[j] == 2) n++;
    }
    return n;
}

/* A generic-for's iterator explist yields a 4th "closing" value that is
 * to-be-closed (Lua §3.3.5). It is present only when the explist can produce a
 * 4th value: an explicit 4th expression, or a trailing call/vararg that might
 * expand to one. */
static int for_gen_has_closing(const Stmt *s) {
    int n = s->as.for_gen.n_exprs;
    if (n >= 4) return 1;
    return n >= 1 && is_multival_tail(s->as.for_gen.exprs[n - 1]);
}

/* Count every to-be-closed slot reachable in this function's body (each <close>
 * declaration, plus each generic-for closing value), NOT descending into nested
 * function bodies. An upper bound on the simultaneously live count, used to
 * pre-size the $tbc backing array. */
static void count_close_in(const Block *b, void *ctx) {
    int *n = ctx;
    *n += count_block_close(b);
    for (size_t i = 0; i < b->count; i++) {
        if (b->items[i]->kind == STMT_FOR_GEN) *n += for_gen_has_closing(b->items[i]);
        for_each_nested_block(b->items[i], count_close_in, ctx);
    }
}
static int count_fn_close(const Block *b) {
    int n = 0;
    count_close_in(b, &n);
    return n;
}

/* Emit a close of the to-be-closed stack down to `target`, with the given 2nd
 * __close argument (null on a structured exit). */
static void emit_close_upto(CG *c, int target, const char *err_wat, int depth) {
    emit_linef(c, depth, "(call $close_upto (ref.as_non_null (local.get $tbc)) "
                         "(i32.const %d) %s)\n",
               target, err_wat);
}

/* The locals and prologue a function/main body needs for <close> support:
 * the per-activation $tbc stack and a snapshot of call_depth at entry (so the
 * error catch can run __close at the right depth). Only emitted when the body
 * actually declares a to-be-closed variable. */
static void emit_tbc_locals(WatBuilder *w, int has_close) {
    if (!has_close) return;
    wat_append(w, "    (local $tbc (ref null $Tbc))\n");
    wat_append(w, "    (local $close_depth i32)\n");
}

static void emit_tbc_init(WatBuilder *w, int n_total) {
    wat_appendf(w, "    (local.set $tbc (struct.new $Tbc (array.new $ArgArr "
                   "(ref.null any) (i32.const %d)) (i32.const 0)))\n",
                n_total);
    wat_append(w, "    (local.set $close_depth (global.get $call_depth))\n");
}

/* Emit a function/main body. With to-be-closed vars, wrap it in one
 * function-level error catch: structured exits (return/break/goto/fall-through)
 * drain the $tbc stack themselves; an error unwind lands here, restores the
 * entry depth, closes whatever is still open with the error object, and
 * rethrows (via $close_upto, which always throws when given an error). */
static void emit_close_body(CG *c, const Block *body, int has_close, int depth) {
    c->close_count = 0;
    if (!has_close) {
        emit_block(c, body, depth);
        return;
    }
    int L = c->next_label++;
    emit_linef(c, depth, "(block $fnclose_done_%d\n", L);
    emit_linef(c, depth + 1, "(block $fnclose_catch_%d (result anyref)\n", L);
    emit_linef(c, depth + 2, "(try_table (catch $LuaError $fnclose_catch_%d)\n", L);
    emit_block(c, body, depth + 3);
    emit_line(c, depth + 2, ")\n"); /* try_table */
    emit_linef(c, depth + 2, "(br $fnclose_done_%d)\n", L);
    emit_line(c, depth + 1, ")\n"); /* fnclose_catch: caught error value on stack */
    emit_line(c, depth + 1, "(local.set $tmp_any)\n");
    emit_line(c, depth + 1, "(global.set $call_depth (local.get $close_depth))\n");
    emit_line(c, depth + 1, "(call $close_upto (ref.as_non_null (local.get $tbc)) "
                            "(i32.const 0) (local.get $tmp_any))\n");
    emit_line(c, depth + 1, "(unreachable)\n");
    emit_line(c, depth, ")\n"); /* fnclose_done */
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
/* Emit a block's statements (label dispatch and all), WITHOUT any <close>
 * handling — emit_block wraps this with the scope push/close calls. */
static void emit_block_stmts(CG *c, const Block *b, int depth) {
    /* Fast path: no labels in this block, no wrappers needed. */
    int has_labels = 0;
    for (size_t i = 0; i < b->count; i++) {
        if (b->items[i]->kind == STMT_LABEL) {
            has_labels = 1;
            break;
        }
    }
    if (!has_labels) {
        for (size_t i = 0; i < b->count; i++) emit_stmt(c, b->items[i], depth);
        return;
    }

    /* Compute segment boundaries: seg_start[k] = index of the first stmt
     * in segment k (k = 0..N). Segment 0 starts at 0; segment k>=1 starts
     * at the position AFTER the k-th label statement. */
    int seg_start[MAX_BLOCK_LABELS + 1]; /* one slot per label + sentinel */
    int N = 0;
    int bid = -1;
    seg_start[0] = 0;
    for (size_t i = 0; i < b->count; i++) {
        Stmt *st = b->items[i];
        if (st->kind != STMT_LABEL) continue;
        if (N == 0) bid = st->as.label.block_dispatch_id;
        N++;
        if (N >= MAX_BLOCK_LABELS) {
            cg_error(c, "too many labels in one block (limit 64)");
            return;
        }
        seg_start[N] = (int)i + 1;
    }
    int seg_end_N = (int)b->count; /* end of segment N */

    /* Reset the dispatch state on entry: $next_BID is a function-scoped
     * local, so a previous entry (e.g. a previous iteration of an
     * enclosing for-loop) would otherwise leave us pointing at the wrong
     * segment. */
    emit_linef(c, depth, "(local.set $next_%d (i32.const 0))\n", bid);
    /* Outer (block $exit_BID) — natural fall-through and gotos exit here. */
    emit_linef(c, depth, "(block $exit_%d\n", bid);
    /* Dispatch loop — backward jumps go through here. */
    emit_linef(c, depth + 1, "(loop $dispatch_%d\n", bid);

    /* Open N+1 nested (block $seg_BID_k …) from outermost (k=N) to innermost (k=0). */
    for (int k = N; k >= 0; k--) {
        emit_linef(c, depth + 2 + (N - k), "(block $seg_%d_%d\n", bid, k);
    }
    /* Innermost: the br_table. Targets in order: seg_0, seg_1, …, seg_N, exit. */
    emit_line(c, depth + 3 + N, "(br_table");
    for (int k = 0; k <= N; k++) wat_appendf(c->w, " $seg_%d_%d", bid, k);
    wat_appendf(c->w, " $exit_%d (local.get $next_%d))\n", bid, bid);
    /* Close the innermost block ($seg_BID_0). */
    emit_line(c, depth + 2 + N, ")\n");

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
            emit_linef(c, body_depth, "(local.set $next_%d (i32.const %d))\n", bid, k + 1);
            emit_linef(c, body_depth, "(br $dispatch_%d)\n", bid);
            /* Close the surrounding $seg_BID_{k+1} block now that this
             * segment's body is complete. */
            emit_line(c, body_depth - 1, ")\n");
        } else {
            /* Last segment: natural exit from the dispatched block. */
            emit_linef(c, body_depth, "(br $exit_%d)\n", bid);
        }
    }
    /* Close the loop and outer block. */
    emit_line(c, depth + 1, ")\n");
    emit_line(c, depth, ")\n");
}

/* Emit a block, applying <close> semantics. A block with no to-be-closed
 * locals is just its statements. Otherwise its <close> declarations push onto
 * the per-activation $tbc stack as they execute (STMT_LOCAL), and on normal
 * fall-through we close the block's own vars (down to the count that was live
 * on entry). Errors, returns, breaks and gotos are closed by those exit paths
 * directly via $close_upto — all draining the same stack, so each var is
 * closed exactly once. */
static void emit_block(CG *c, const Block *b, int depth) {
    if (count_block_close(b) == 0) {
        emit_block_stmts(c, b, depth);
        return;
    }
    int base = c->close_count;
    emit_block_stmts(c, b, depth);
    /* STMT_LOCAL bumped close_count for each <close> it emitted; close them. */
    if (c->close_count > base) emit_close_upto(c, base, "(ref.null any)", depth);
    c->close_count = base;
}

/* Walk a block body collecting dispatch ids of every block-with-labels.
 * Output is the set of distinct ids (no duplicates because each block's
 * dispatch id is uniquely the id of its first label). On overflow this raises
 * a codegen error rather than dropping ids — a dropped id would leave its
 * $next_<id> local undeclared, producing invalid WAT. */
typedef struct {
    CG *c;
    int *out, *n, cap;
} DispatchIds;
static void collect_dispatch_ids_in(const Block *b, void *ctx) {
    DispatchIds *d = ctx;
    /* Find the first label in this block (if any) — its id is the dispatch id. */
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *st = b->items[i];
        if (st->kind == STMT_LABEL) {
            if (*d->n >= d->cap) {
                cg_error(d->c, "too many label-bearing blocks in one function");
                return;
            }
            d->out[(*d->n)++] = st->as.label.block_dispatch_id;
            break;
        }
    }
    for (size_t i = 0; i < b->count && d->c->ok; i++) for_each_nested_block(b->items[i], collect_dispatch_ids_in, d);
}
static void collect_dispatch_ids(CG *c, const Block *b, int *out, int *n, int cap) {
    collect_dispatch_ids_in(b, &(DispatchIds){c, out, n, cap});
}

/* Deepest nesting of numeric/generic for-loops in a block. Each for-loop
 * adds one level; other compound statements pass their inner depth through
 * unchanged (only for-loops own $for_* scratch). The result sizes the
 * per-level scratch declarations in the function prologue. */
static void max_for_nesting_in(const Block *b, void *ctx);
static int max_for_nesting(const Block *b) {
    int best = 0;
    if (!b) return 0;
    for (size_t i = 0; i < b->count; i++) {
        const Stmt *s = b->items[i];
        int d = 0;
        for_each_nested_block(s, max_for_nesting_in, &d);
        if (s->kind == STMT_FOR_NUM || s->kind == STMT_FOR_GEN) d++;
        if (d > best) best = d;
    }
    return best;
}
static void max_for_nesting_in(const Block *b, void *ctx) {
    int *d = ctx, v = max_for_nesting(b);
    if (v > *d) *d = v;
}

/* Emit the per-level $for_* scratch locals for a function body. */
static void emit_for_scratch_locals(WatBuilder *w, const Block *body) {
    int levels = max_for_nesting(body);
    for (int d = 0; d < levels; d++) {
        wat_appendf(w,
                    "    (local $for_stop_%d anyref) (local $for_step_%d anyref)"
                    " (local $for_next_%d anyref) (local $for_cur_%d anyref)"
                    " (local $for_skip_%d i32)\n",
                    d, d, d, d, d);
        wat_appendf(w,
                    "    (local $for_iter_%d anyref) (local $for_state_%d anyref)"
                    " (local $for_k_%d anyref)\n",
                    d, d, d);
    }
}

/* ============================================================
 * Static prelude
 * ============================================================ */

static const char PRELUDE[] = {
#embed "prelude.wat"
    , '\0'};

/* The first LITERAL_PREFIX_LEN bytes of $str_data are reserved error
 * messages and field names that prelude.wat addresses by *absolute* offset
 * (e.g. `$throw_lit (i32.const 430) (i32.const 25)`). The byte map lives in
 * LITERAL_SLAB below; verify_literal_slab() checks that LITERAL_PREFIX and
 * that map agree, so an edit to one without the other fails the build
 * instead of silently corrupting messages or reading past the slab. */
#define LITERAL_PREFIX     "niltruefalse<float>numberstringtablefunctionboolean__index__add__eq\tLua 5.5'for' step is zeroattempt to call a non-function value__callmodule '' not loadedvalue out of rangedata does not fitinvalid UTF-8 codeattempt to perform arithmeticattempt to index a valuetable index is niltable index is NaNtoo largeyearmonthdayhourminsecwdayydayisdsttable overflowout of limitsmissing sizevariable-length formatnot power of 2invalid formatattempt to divide by zeroattempt to perform 'n%0'attempt to compare two values'__tostring' must return a string'__newindex' chain too long; possible loopattempt to close a non-closable valuevalue expectedcannot change a protected metatablestring expectedtable expectedtable or string expectedinvalid replacement valuestring contains zeros<no error object>invalid value in table for 'concat'base out of rangeposition out of boundsinitial position is a continuation bytefield missing in date tablewrong number of argumentsnumber expected, got stack overflownumber has no integer representationinvalid key to 'next'function expectedfield is not an integervariable got a non-closable valueinvalid order function for sortingbad 'for' limit (bad 'for' step (bad 'for' initial value ()"
#define LITERAL_PREFIX_LEN 1208
static_assert(sizeof(LITERAL_PREFIX) - 1 == LITERAL_PREFIX_LEN,
              "LITERAL_PREFIX_LEN must match the byte length of LITERAL_PREFIX");

/* Executable form of the slab map. Each row is the absolute offset baked
 * into prelude.wat and the bytes that must live there. Offsets are
 * contiguous (each = previous offset + previous length); the trailing
 * comment names the prelude consumer. */
static const struct {
    unsigned off;
    const char *s;
} LITERAL_SLAB[] = {
    {0, "nil"},
    {3, "true"},
    {7, "false"},
    {12, "<float>"},
    {19, "number"},
    {25, "string"},
    {31, "table"},
    {36, "function"},
    {44, "boolean"},
    {51, "__index"},
    {58, "__add"},
    {63, "__eq"},
    {67, "\t"},
    {68, "Lua 5.5"},
    {75, "'for' step is zero"},                   /* $for_prep / int for-loop */
    {93, "attempt to call a non-function value"}, /* $lua_call_any */
    {129, "__call"},                              /* $g_mkey_call */
    {135, "module '"},
    {143, "' not loaded"},                  /* $builtin_require */
    {155, "value out of range"},            /* $builtin_string_char, … */
    {173, "data does not fit"},             /* $builtin_string_unpack */
    {190, "invalid UTF-8 code"},            /* $builtin_utf8_codepoint, … */
    {208, "attempt to perform arithmetic"}, /* $arith_mm */
    {237, "attempt to index a value"},      /* $lua_tabset, $lua_index */
    {261, "table index is nil"},            /* $builtin_rawset, $tab_set */
    {279, "table index is NaN"},            /* $builtin_rawset, $tab_set */
    {297, "too large"},                     /* $builtin_string_rep */
    {306, "year"},
    {310, "month"},
    {315, "day"},
    {318, "hour"}, /* os.date("*t") */
    {322, "min"},
    {325, "sec"},
    {328, "wday"},
    {332, "yday"},
    {336, "isdst"},
    {341, "table overflow"},                             /* $tab_grow size guard */
    {355, "out of limits"},                              /* pack size/align validation */
    {368, "missing size"},                               /* pack 'c' missing [N] */
    {380, "variable-length format"},                     /* packsize on 's'/'z' */
    {402, "not power of 2"},                             /* pack '!N' validation */
    {416, "invalid format"},                             /* packsize 'c' overflow */
    {430, "attempt to divide by zero"},                  /* $lua_fdiv divisor 0 */
    {455, "attempt to perform 'n%0'"},                   /* $lua_mod divisor 0 */
    {479, "attempt to compare two values"},              /* $compare_mm */
    {508, "'__tostring' must return a string"},          /* $lua_tostring */
    {541, "'__newindex' chain too long; possible loop"}, /* $lua_tabset */
    {583, "attempt to close a non-closable value"},      /* $do_close */
    {620, "value expected"},                             /* pcall/xpcall/select */
    {634, "cannot change a protected metatable"},        /* $builtin_setmetatable */
    {669, "string expected"},                            /* require/os.getenv */
    {684, "table expected"},                             /* $builtin_rawget */
    {698, "table or string expected"},                   /* $builtin_rawlen */
    {722, "invalid replacement value"},                  /* gsub replacement paths */
    {747, "string contains zeros"},                      /* $builtin_string_pack 'z' */
    {768, "<no error object>"},                          /* $err_or_noobj */
    {785, "invalid value in table for 'concat'"},        /* $builtin_table_concat */
    {820, "base out of range"},                          /* $builtin_tonumber */
    {837, "position out of bounds"},                     /* $builtin_utf8_offset */
    {859, "initial position is a continuation byte"},    /* $builtin_utf8_offset */
    {898, "field missing in date table"},                /* $os_date_field */
    {925, "wrong number of arguments"},                  /* $builtin_table_insert */
    {950, "number expected, got "},                      /* $as_float_co / $as_int_co */
    {971, "stack overflow"},                             /* $push_call_frame depth guard */
    {985, "number has no integer representation"},       /* $as_int_co */
    {1021, "invalid key to 'next'"},                     /* $builtin_next */
    {1042, "function expected"},                         /* $builtin_table_sort */
    {1059, "field is not an integer"},                   /* $os_date_field */
    {1082, "variable got a non-closable value"},         /* $check_closable */
    {1115, "invalid order function for sorting"},        /* $partition */
    {1149, "bad 'for' limit ("},                         /* $for_limit / $for_prep */
    {1166, "bad 'for' step ("},                          /* $for_prep */
    {1182, "bad 'for' initial value ("},                 /* $for_prep */
    {1207, ")"},                                         /* $for_error */
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
    return t == NT_INT ? "i64" : t == NT_FLOAT ? "f64"
                                               : "anyref";
}

/* Emit the body of one user function. */
/* Estimated wasm frame bytes of $user_N, stored in every closure over it for
 * the stack-budget guard ($push_call_frame). An upper bound that needs none
 * of the per-function analyses: every slot counted as a maybe quadruple, the
 * temporary bound taken with no typing information (larger), eight bytes a
 * local, plus a fixed allowance for the call machinery's own frames. */
static int fn_frame_weight(CG *c, const LuaFunc *fn) {
    const unsigned char *pi = c->cur_is_int, *pf = c->cur_is_float, *pm = c->cur_is_maybe;
    int pn = c->cur_n_locals;
    c->cur_is_int = NULL;
    c->cur_is_float = NULL;
    c->cur_is_maybe = NULL;
    c->cur_n_locals = fn->n_locals;
    int temps = c->opt_int ? block_temp_need(c, &fn->body) : 0;
    c->cur_is_int = pi;
    c->cur_is_float = pf;
    c->cur_is_maybe = pm;
    c->cur_n_locals = pn;
    int locals = fn->n_locals * 4 + temps * 4 + 16;
    return 8 * locals + 300;
}

static void emit_user_function(CG *c, const LuaFunc *fn, FnEntry entry) {
    WatBuilder *w = c->w;
    int direct = entry == ENTRY_DIRECT || entry == ENTRY_DIRECT1;
    int fast = entry == ENTRY_FAST;
    const FuncSig *sg = (c->opt_int && fn->func_idx >= 0 && fn->func_idx < c->n_sigs)
                            ? &c->sigs[fn->func_idx]
                            : NULL;
    /* Typed direct entries seed their parameter slots from the signature; the
     * generic entry and the main chunk leave parameters boxed. */
    const NumTy *param_seed = (direct && sg) ? sg->param_ty : NULL;
    NumTy ret_ty = (entry == ENTRY_DIRECT1 && sg) ? sg->ret_ty : NT_ANY;
    if (direct) {
        /* Direct-args entry: closure + one (typed) param per declared parameter,
         * no $args/$ArgArr. $user_N_da1 returns a single value of
         * the inferred result type; otherwise ($user_N_da) the array-based
         * return. Same body as $user_N either way. */
        wat_appendf(w, "  (func $user_%d_%s (param $closure (ref $LuaClosure))",
                    fn->func_idx, entry == ENTRY_DIRECT1 ? "da1" : "da");
        for (int i = 0; i < fn->n_params; i++)
            wat_appendf(w, " (param $p%d %s)", i,
                        num_wat_ty(param_seed ? param_seed[i] : NT_ANY));
        if (entry == ENTRY_DIRECT1) wat_appendf(w, " (result %s)\n", num_wat_ty(ret_ty));
        else wat_append(w, " (result (ref $ArgArr))\n");
    } else if (fast) {
        /* Fast entry ($LuaFn1): arguments in $a0..$a3, $nargs of them; one
         * result. Parameters are untyped, like the generic entry. */
        wat_appendf(w,
                    "  (func $user_%d_f (type $LuaFn1) (param $closure (ref $LuaClosure)) "
                    "(param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) "
                    "(param $nargs i32) (result anyref)\n",
                    fn->func_idx);
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
    unsigned char *isint = NULL, *isfloat = NULL, *ismaybe = NULL;
    int any_maybe = 0;
    if (c->opt_int) {
        /* The int/float slot analysis recognizes direct calls (expr_is_int on
         * EXPR_CALL needs cur_func_slot/cur_upval_func, set just above), so a
         * slot assigned the result of an int-returning call is itself typed int. */
        isint = calloc(fn->n_locals ? fn->n_locals : 1, 1);
        compute_int_slots(c, &fn->body, fn->n_locals, fn->n_params, fn->captured, isint, param_seed);
        c->cur_is_int = isint;
        isfloat = calloc(fn->n_locals ? fn->n_locals : 1, 1);
        compute_float_slots(c, &fn->body, fn->n_locals, fn->n_params, fn->captured, isfloat, param_seed);
        c->cur_is_float = isfloat;
        ismaybe = calloc(fn->n_locals ? fn->n_locals : 1, 1);
        any_maybe = compute_maybe_slots(c, &fn->body, fn->n_locals, fn->n_params, fn->captured, ismaybe);
    }
    c->cur_is_int = isint;
    c->cur_is_float = isfloat;
    const unsigned char *prev_is_maybe = c->cur_is_maybe;
    int prev_mt_max = c->mt_max, prev_mt_depth = c->mt_depth;
    c->cur_is_maybe = ismaybe;
    c->mt_depth = 0;
    /* Lowering also fires on opaque operands with no maybe slot in sight, so
     * the temporaries are sized whenever the specializer is on. */
    c->mt_max = c->opt_int ? block_temp_need(c, &fn->body) : 0;
    (void)any_maybe;

    /* Run the label pre-pass NOW so block_dispatch_id is populated on
     * every label and goto before we emit the $next_BID i32 locals. */
    int saved_next_id_pre = c->next_label_id;
    c->next_label_id = 0;
    la_close_bases(&fn->body, 0);
    la_block(c, &fn->body, NULL);

    for (int i = 0; i < fn->n_locals; i++) {
        if (isint && isint[i]) {
            wat_appendf(w, "    (local $L%d i64)\n", i);
        } else if (isfloat && isfloat[i]) {
            wat_appendf(w, "    (local $L%d f64)\n", i);
        } else if (ismaybe && ismaybe[i]) {
            wat_appendf(w, "    (local $L%d anyref) (local $Lt%d i32) (local $Li%d i64) (local $Lf%d f64)\n",
                        i, i, i, i);
        } else if (fn->captured && fn->captured[i]) {
            wat_appendf(w, "    (local $L%d (ref $Box))\n", i);
        } else {
            wat_appendf(w, "    (local $L%d anyref)\n", i);
        }
    }
    for (int k = 0; k < c->mt_max; k++)
        wat_appendf(w, "    (local $mt%d anyref) (local $mg%d i32) (local $mi%d i64) (local $mf%d f64)\n",
                    k, k, k, k);
    wat_append(w, "    (local $tmp_any anyref)\n");
    wat_append(w, "    (local $tmp_args (ref null $ArgArr))\n");
    wat_append(w, "    (local $tmp_clo (ref null $LuaClosure))\n");
    wat_append(w, "    (local $tmp_callee anyref)\n");
    wat_append(w, "    (local $tmp_tab (ref null $LuaTable))\n");
    wat_append(w, "    (local $tmp_lhs_t (ref null $ArgArr))\n");
    wat_append(w, "    (local $tmp_lhs_k (ref null $ArgArr))\n");
    if (fast) wat_append(w, "    (local $ta0 anyref) (local $ta1 anyref) (local $ta2 anyref) (local $ta3 anyref)\n");
    int fn_n_close = count_fn_close(&fn->body);
    emit_tbc_locals(w, fn_n_close > 0);
    emit_for_scratch_locals(w, &fn->body);
    if (c->opt_int) {
        int lv = max_for_nesting(&fn->body);
        for (int d = 0; d < lv; d++)
            wat_appendf(w, "    (local $ifor_stop_%d i64) (local $ifor_step_%d i64)"
                           " (local $ifor_next_%d i64)\n",
                        d, d, d);
    }
    if (fn->is_vararg) {
        /* Non-null: prologue always writes $varargs before first use. */
        wat_append(w, "    (local $varargs (ref $ArgArr))\n");
    }
    /* Pre-pass found these; emit one i32 local per dispatch block in this
     * function so STMT_GOTO can target them and emit_block can read them
     * in br_table. Default-zero i32 ⇒ first dispatch lands in segment 0. */
    {
        int bids[MAX_DISPATCH_IDS];
        int n = 0;
        collect_dispatch_ids(c, &fn->body, bids, &n, MAX_DISPATCH_IDS);
        for (int i = 0; i < n; i++) {
            wat_appendf(w, "    (local $next_%d i32)\n", bids[i]);
        }
    }

    /* Param extraction: from args[i] (normal), the direct $pi param, or the
     * fast entry's $ai register (nil when the call passed fewer). */
    for (int i = 0; i < fn->n_params; i++) {
        char src[64];
        int sn = direct ? snprintf(src, sizeof src, "(local.get $p%d)", i)
                 : fast ? snprintf(src, sizeof src, "(local.get $a%d)", i)
                        : snprintf(src, sizeof src, "(call $args_at (local.get $args) (i32.const %d))", i);
        if (sn < 0 || (size_t)sn >= sizeof src) {
            cg_error(c, "param-extraction expression too long");
            return;
        }
        if (fn->captured && fn->captured[i])
            wat_appendf(w, "    (local.set $L%d (struct.new $Box %s))\n", i, src);
        else
            wat_appendf(w, "    (local.set $L%d %s)\n", i, src);
        if (ismaybe && ismaybe[i])
            wat_appendf(w,
                        "    (call $unbox_num (local.get $L%d))\n"
                        "    local.set $Lf%d\n    local.set $Li%d\n    local.set $Lt%d\n",
                        i, i, i, i);
    }
    if (fn->is_vararg && fast) {
        wat_appendf(w,
                    "    (local.set $varargs (call $varargs_tail4 (local.get $a0) (local.get $a1) "
                    "(local.get $a2) (local.get $a3) (i32.const %d) (local.get $nargs)))\n",
                    fn->n_params);
    } else if (fn->is_vararg) {
        wat_appendf(w,
                    "    (local.set $varargs (call $args_slice "
                    "(local.get $args) (i32.const %d)))\n",
                    fn->n_params);
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
    if (fn_n_close > 0) emit_tbc_init(w, fn_n_close);

    int was_in_main = c->in_main;
    FnEntry prev_entry = c->entry;
    NumTy prev_ret_ty = c->cur_ret_ty;
    c->in_main = 0;
    c->entry = entry;
    c->cur_ret_ty = ret_ty;
    if (c->ok) emit_close_body(c, &fn->body, fn_n_close > 0, 2);
    c->next_label_id = saved_next_id_pre;
    c->in_main = was_in_main;
    c->entry = prev_entry;
    c->cur_ret_ty = prev_ret_ty;

    /* Default trailing fall-through value. A numeric ret_ty implies the body
     * always returns (block_always_returns), so this default is dead but must
     * still type-check; otherwise it is nil / the empty results array. */
    if (entry == ENTRY_DIRECT1 || entry == ENTRY_FAST)
        wat_appendf(w, "    %s\n", ret_ty == NT_INT ? "(i64.const 0)" : ret_ty == NT_FLOAT ? "(f64.const 0)"
                                                                                           : "(ref.null any)");
    else
        wat_append(w, "    (global.get $g_empty_args)\n");
    wat_append(w, "  )\n");

    /* Declare so the funcref is usable in const init / closures. The direct
     * entry is only ever called by name, so it needs no elem declare. */
    if (fast) wat_appendf(w, "  (elem declare func $user_%d_f)\n", fn->func_idx);
    else if (!direct) wat_appendf(w, "  (elem declare func $user_%d)\n", fn->func_idx);

    c->cur_captured = prev_captured;
    c->cur_n_locals = prev_n_locals;
    c->cur_is_int = prev_is_int;
    c->cur_is_float = prev_is_float;
    c->cur_is_maybe = prev_is_maybe;
    c->mt_max = prev_mt_max;
    c->mt_depth = prev_mt_depth;
    free(ismaybe);
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
    unsigned char *live; /* builtin idx -> 1 if referenced */
    unsigned char *gref; /* pr->globals idx -> 1 if referenced */
    int n_builtins;
    int n_globals;
    /* Set when the program can reach a builtin/global the static walk can't
     * enumerate, so the live/gref sets are NOT a complete picture: any mention
     * of _G/_ENV (the whole env table, indexable by a computed name) or of the
     * load/require builtins (they resolve names / whole modules at runtime).
     * When it stays clear the program is "globally closed" and dropping
     * un-referenced builtins is sound — codegen_module tree-shakes by default
     * in that case (see its effective_tree_shake). */
    int escaped;
    /* Set when the program method-calls or field-indexes a value that could be
     * a string (`s:upper()`, `s.len`): Lua strings carry an implicit metatable
     * whose __index is the `string` library, so that library must stay live
     * even when the program never writes the name `string`. Method-call and
     * index syntax are the only ways to reach it; both are conservatively
     * treated as possibly-on-a-string. */
    int uses_string_meta;
    /* Set when the program touches anything $stdlib_init builds — a builtin or
     * global (read or written via _G), a call/method-call (callee dispatch /
     * __call), an index (__index/__newindex), any operator (boxed helpers read
     * metamethod-key globals), a table constructor, or either for-loop form
     * (iterator protocol / bad-bound error path). When it stays clear the
     * program observes no runtime state, so $main skips the `(call $stdlib_init)`
     * and DCE drops the runtime wholesale. Conservative: it only keeps a call an
     * exact reachability analysis would drop, never drops one it would keep. */
    int needs_runtime;
} LiveSet;

static void ts_mark_expr(LiveSet *L, const Expr *e);
static void ts_mark_stmt(const Stmt *s, void *ctx);
static int class_for_global(const char *name, size_t name_len); /* defined below */
static void ts_mark_block(LiveSet *L, const Block *b) {
    if (b) walk_stmts(b, ts_mark_stmt, L);
}

static void ts_mark_var(LiveSet *L, VarKind k, int idx) {
    if (k == VAR_BUILTIN || k == VAR_GLOBAL) L->needs_runtime = 1; /* reaches _G / a builtin */
    if (k == VAR_BUILTIN && idx >= 0 && idx < L->n_builtins) L->live[idx] = 1;
    else if (k == VAR_GLOBAL && idx >= 0 && idx < L->n_globals) L->gref[idx] = 1;
}

/* Does this variable reference open an escape hatch the static walk can't
 * follow? _G/_ENV expose the whole environment to computed-name indexing;
 * load/require pull in code/modules that can name anything. */
static int var_escapes(VarKind kind, const char *name, size_t len) {
    if (kind == VAR_GLOBAL)
        return (len == 2 && memcmp(name, "_G", 2) == 0) ||
               (len == 4 && memcmp(name, "_ENV", 4) == 0);
    if (kind == VAR_BUILTIN)
        return (len == 4 && memcmp(name, "load", 4) == 0) ||
               (len == 7 && memcmp(name, "require", 7) == 0);
    return 0;
}

/* Is the value indexed / method-called here statically guaranteed NOT to be a
 * string? Then the string metatable can't apply and the `string` library
 * needn't be kept on its account. Only bases the compiler fully resolves to a
 * non-string qualify: a known library global (math.sin, table.insert), a
 * builtin (a function), or a table constructor. A local/upvalue, a user global,
 * or any computed result could hold a string, so those keep the library. */
static int index_base_is_nonstring(const Expr *e) {
    if (!e) return 0;
    switch (e->kind) {
    case EXPR_VAR:
        if (e->as.var.kind == VAR_BUILTIN) return 1;
        if (e->as.var.kind == VAR_GLOBAL)
            return class_for_global(e->as.var.name, e->as.var.name_len) >= 0;
        return 0;
    case EXPR_TABLE: return 1;
    default: return 0;
    }
}

static void ts_mark_expr(LiveSet *L, const Expr *e) {
    if (!e) return;
    switch (e->kind) {
    case EXPR_VAR:
        if (var_escapes(e->as.var.kind, e->as.var.name, e->as.var.name_len)) L->escaped = 1;
        ts_mark_var(L, e->as.var.kind, e->as.var.idx);
        break;
    case EXPR_CALL:
        L->needs_runtime = 1; /* callee dispatch / __call */
        ts_mark_expr(L, e->as.call.callee);
        for (size_t i = 0; i < e->as.call.nargs; i++)
            ts_mark_expr(L, e->as.call.args[i]);
        break;
    case EXPR_BINOP:
        L->needs_runtime = 1; /* boxed helpers read metamethod-key globals */
        ts_mark_expr(L, e->as.binop.lhs);
        ts_mark_expr(L, e->as.binop.rhs);
        break;
    case EXPR_UNOP:
        L->needs_runtime = 1;
        ts_mark_expr(L, e->as.unop.operand);
        break;
    case EXPR_FUNCTION:
        ts_mark_block(L, &e->as.func_expr.func->body);
        break;
    case EXPR_INDEX:
        L->needs_runtime = 1; /* __index */
        if (!index_base_is_nonstring(e->as.index.table))
            L->uses_string_meta = 1; /* could be a field access on a string */
        ts_mark_expr(L, e->as.index.table);
        ts_mark_expr(L, e->as.index.key);
        break;
    case EXPR_TABLE:
        L->needs_runtime = 1; /* allocates + __newindex on field set */
        for (int i = 0; i < e->as.table_ctor.n_entries; i++) {
            ts_mark_expr(L, e->as.table_ctor.entries[i].key);
            ts_mark_expr(L, e->as.table_ctor.entries[i].value);
        }
        break;
    case EXPR_METHOD_CALL:
        L->needs_runtime = 1; /* index + call */
        if (!index_base_is_nonstring(e->as.method_call.recv))
            L->uses_string_meta = 1; /* receiver could be a string */
        ts_mark_expr(L, e->as.method_call.recv);
        for (size_t i = 0; i < e->as.method_call.nargs; i++)
            ts_mark_expr(L, e->as.method_call.args[i]);
        break;
    default: break; /* literals, vararg — no refs */
    }
}

static void ts_mark_expr_visit(const Expr *e, void *ctx) { ts_mark_expr(ctx, e); }
static void ts_mark_stmt(const Stmt *s, void *ctx) {
    LiveSet *L = ctx;
    for_each_own_expr(s, ts_mark_expr_visit, L);
    switch (s->kind) {
    case STMT_ASSIGN:
        for (int i = 0; i < s->as.assign.n_targets; i++) {
            const AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind == TGT_INDEX) L->needs_runtime = 1; /* t[k] = v -> __newindex */
            else ts_mark_var(L, t->as.var.kind, t->as.var.idx);
        }
        break;
    case STMT_LOCAL_FUNC: ts_mark_block(L, &s->as.local_func.func->body); break;
    case STMT_FOR_NUM: L->needs_runtime = 1; break; /* the bad-bound error path reads $g_src_name */
    case STMT_FOR_GEN: L->needs_runtime = 1; break; /* the generic-for iterator protocol */
    case STMT_GLOBAL: L->needs_runtime = 1; break;  /* declares / writes a module global via _G */
    default: break;
    }
}

/* Map a global name to a BuiltinClass if it's one of the pre-declared
 * library tables. Returns -1 otherwise. */
static int class_for_global(const char *name, size_t name_len) {
    if (name_len == 4 && memcmp(name, "math", 4) == 0) return BLT_LIB_MATH;
    if (name_len == 6 && memcmp(name, "string", 6) == 0) return BLT_LIB_STRING;
    if (name_len == 2 && memcmp(name, "io", 2) == 0) return BLT_LIB_IO;
    if (name_len == 5 && memcmp(name, "table", 5) == 0) return BLT_LIB_TABLE;
    if (name_len == 4 && memcmp(name, "utf8", 4) == 0) return BLT_LIB_UTF8;
    if (name_len == 5 && memcmp(name, "debug", 5) == 0) return BLT_LIB_DEBUG;
    if (name_len == 2 && memcmp(name, "os", 2) == 0) return BLT_LIB_OS;
    return -1;
}

static void compute_live_set(const ParseResult *pr, int n_builtins, unsigned char *live,
                             unsigned char *gref, int *out_escaped, int *out_needs_runtime) {
    LiveSet L = {.live = live,
                 .gref = gref,
                 .n_builtins = n_builtins,
                 .n_globals = (int)pr->globals.count};
    ts_mark_block(&L, &pr->main_body);
    for (size_t i = 0; i < pr->funcs.count; i++)
        ts_mark_block(&L, &pr->funcs.items[i]->body);
    if (out_escaped) *out_escaped = L.escaped;
    if (out_needs_runtime) *out_needs_runtime = L.needs_runtime;

    /* Strings carry an implicit metatable whose __index is the `string`
     * library, so any method-call / field-index that could land on a string
     * keeps that library live even if the name `string` never appears. Mark
     * the library global referenced so its table is installed, then the
     * class-expansion below pulls in its members. */
    if (L.uses_string_meta) {
        for (size_t gi = 0; gi < pr->globals.count; gi++)
            if (class_for_global(pr->globals.items[gi].name,
                                 pr->globals.items[gi].name_len) == BLT_LIB_STRING)
                gref[gi] = 1;
    }

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
     * prelude funcs), so the assembler would reject an unresolved global.
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
            (strcmp(n, "_file_read") == 0 || strcmp(n, "_file_write") == 0 ||
             strcmp(n, "_file_close") == 0 || strcmp(n, "_file_flush") == 0 ||
             strcmp(n, "_file_seek") == 0 || strcmp(n, "_file_lines") == 0 ||
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
        if (glen == 2 && memcmp(gname, "_G", 2) == 0) continue; /* installed above */
        if (!gref[gi]) continue;                                /* tree-shake: library not referenced */
        if (glen == 7 && memcmp(gname, "package", 7) == 0) {
            /* Milestone 25: package = { loaded = {}, preload = {} }.
             * No builtins live under this table; require() walks it.
             * We also stub package.path, package.cpath, package.config so
             * tests that probe `type(package.path) == "string"` pass. */
            wat_append(out, "    (local.set $tab (call $tab_new))\n");
            static const struct {
                const char *key;
                const char *val;
            } PKG_STR[] = {
                {"loaded", NULL}, /* table — handled separately */
                {"preload", NULL},
                {"path", ""}, /* empty: there's no filesystem here */
                {"cpath", ""},
                {"config", "/\n;\n?\n!\n-\n"}, /* the stock Lua default */
            };
            for (size_t pi = 0; pi < sizeof(PKG_STR) / sizeof(PKG_STR[0]); pi++) {
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
        if (glen == 9 && memcmp(gname, "coroutine", 9) == 0) {
            /* Empty stub library — no functions installed. Enough to
             * satisfy `require "coroutine" == coroutine` style identity
             * checks and to keep `type(coroutine) == "table"` happy;
             * any actual coroutine.* call still trips later. */
            wat_append(out, "    (local.set $tab (call $tab_new))\n");
            emit_tab_set_str(c, G, gname, glen, "(local.get $tab)");
            continue;
        }
        /* The function-bearing libraries (math/string/io/table/utf8/debug/os)
         * map name -> BuiltinClass via the same helper the live-set pass uses. */
        int cls_i = class_for_global(gname, glen);
        if (cls_i < 0) continue;
        BuiltinClass cls = (BuiltinClass)cls_i;
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
            emit_tab_set_global(c, "$tab", key, strlen(key), builtin_func_name(bi) + 1);
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
                size_t handle_len;
                const char *method_glob;
                int fd;                     /* host fd; io.type reads __fd */
                const char *default_global; /* capture as a default io file, or NULL */
            } HANDLES[] = {
                {"stdout", 6, "io_handle_write", 1, "$g_io_output"},
                {"stderr", 6, "io_handle_err_write", 2, NULL},
                {"stdin", 5, NULL, 0, "$g_io_input"},
            };
            for (size_t hi = 0; hi < sizeof(HANDLES) / sizeof(HANDLES[0]); hi++) {
                wat_append(out, "    (local.set $h (call $tab_new))\n");
                if (HANDLES[hi].method_glob)
                    emit_tab_set_global(c, "$h", "write", 5, HANDLES[hi].method_glob);
                else
                    emit_tab_set_global(c, "$h", "read", 4, "io_handle_read");
                emit_tab_set_global(c, "$h", "close", 5, "io_handle_noop");
                emit_tab_set_global(c, "$h", "flush", 5, "io_handle_noop");
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
            "math",
            "string",
            "io",
            "table",
            "utf8",
            "debug",
            "package",
            "os",
            "coroutine",
        };
        int need_any = 0;
        for (size_t li = 0; li < sizeof(LIB_NAMES) / sizeof(LIB_NAMES[0]); li++) {
            size_t llen = strlen(LIB_NAMES[li]);
            for (size_t gi = 0; gi < pr->globals.count; gi++) {
                if (pr->globals.items[gi].name_len == llen &&
                    memcmp(pr->globals.items[gi].name, LIB_NAMES[li], llen) == 0 &&
                    gref[gi]) {
                    need_any = 1;
                    break;
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
                gref[gi]) {
                have_package = 1;
                break;
            }
        }
        if (need_any && have_package) {
            char pkg_e[160], loaded_e[160];
            kstr_expr(c, "package", 7, pkg_e, sizeof pkg_e);
            kstr_expr(c, "loaded", 6, loaded_e, sizeof loaded_e);
            wat_appendf(out,
                        "    (local.set $tab (ref.cast (ref $LuaTable)\n"
                        "      (call $tab_get\n"
                        "        (ref.cast (ref $LuaTable) (call $tab_get\n"
                        "          (ref.as_non_null (global.get $g_globals)) %s))\n"
                        "        %s)))\n",
                        pkg_e, loaded_e);
            for (size_t li = 0; li < sizeof(LIB_NAMES) / sizeof(LIB_NAMES[0]); li++) {
                size_t llen = strlen(LIB_NAMES[li]);
                int gi_found = -1;
                for (size_t gi = 0; gi < pr->globals.count; gi++) {
                    if (pr->globals.items[gi].name_len == llen &&
                        memcmp(pr->globals.items[gi].name, LIB_NAMES[li], llen) == 0 &&
                        gref[gi]) {
                        gi_found = (int)gi;
                        break;
                    }
                }
                if (gi_found < 0) continue;
                char name_e[160];
                kstr_expr(c, LIB_NAMES[li], llen, name_e, sizeof name_e);
                wat_appendf(out,
                            "    (call $tab_set (local.get $tab) %s\n"
                            "      (call $tab_get (ref.as_non_null (global.get $g_globals)) %s))\n",
                            name_e, name_e);
            }
        }
    }
}

/* --- table-write detection (the DCE gate for $tab_bootstrap_set) -------- *
 * The bootstrap can install _G/library entries with either $tab_set or the
 * append-only $tab_bootstrap_set. The latter never references the table grow/
 * rehash/array-spill machinery, so for a program that performs no table writes
 * of its own the whole write path goes unreferenced and the DCE pass drops it
 * (~1KB on a minimal tree-shaken module). When the program *does* write a
 * table the write path stays live regardless and the extra helper would be
 * pure overhead, so we fall back to $tab_set.
 *
 * This is purely a size heuristic — both inserts populate _G identically, so a
 * false positive only forgoes the win, never miscompiles. We flag any global
 * or indexed assignment and any table constructor. A write reachable only
 * through a builtin (rawset / table.insert / require) is not detected here; in
 * that case bootstrap_set is a small, rare overhead, not a correctness issue. */
static int expr_writes_table(const Expr *e);
static int exprs_write_table(Expr **es, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (expr_writes_table(es[i])) return 1;
    return 0;
}
static int expr_writes_table(const Expr *e) {
    if (!e) return 0;
    switch (e->kind) {
    case EXPR_TABLE: return 1; /* a constructor writes the new table */
    case EXPR_CALL:
        return expr_writes_table(e->as.call.callee) ||
               exprs_write_table(e->as.call.args, e->as.call.nargs);
    case EXPR_METHOD_CALL:
        return expr_writes_table(e->as.method_call.recv) ||
               exprs_write_table(e->as.method_call.args, e->as.method_call.nargs);
    case EXPR_BINOP:
        return expr_writes_table(e->as.binop.lhs) || expr_writes_table(e->as.binop.rhs);
    case EXPR_UNOP: return expr_writes_table(e->as.unop.operand);
    case EXPR_INDEX:
        return expr_writes_table(e->as.index.table) || expr_writes_table(e->as.index.key);
    default: return 0; /* EXPR_FUNCTION bodies are visited via pr->funcs */
    }
}
static void writes_table_expr(const Expr *e, void *ctx) {
    int *w = ctx;
    if (!*w) *w = expr_writes_table(e);
}
static void writes_table_stmt(const Stmt *s, void *ctx) {
    int *w = ctx;
    if (*w) return;
    if (s->kind == STMT_GLOBAL && s->as.global_decl.n_values > 0) *w = 1; /* `global x = ...` writes _G */
    if (s->kind == STMT_ASSIGN)
        for (int i = 0; i < s->as.assign.n_targets; i++) {
            const AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind == TGT_INDEX) *w = 1; /* t[k] = v */
            if (t->kind == TGT_VAR && (t->as.var.kind == VAR_GLOBAL || t->as.var.kind == VAR_BUILTIN))
                *w = 1; /* global write goes through _G */
        }
    for_each_own_expr(s, writes_table_expr, w); /* LOCAL_FUNC bodies: via pr->funcs */
}
static int block_writes_table(const Block *b) {
    int w = 0;
    walk_stmts(b, writes_table_stmt, &w);
    return w;
}
static int program_writes_table(const ParseResult *pr) {
    if (block_writes_table(&pr->main_body)) return 1;
    for (size_t i = 0; i < pr->funcs.count; i++)
        if (block_writes_table(&pr->funcs.items[i]->body)) return 1;
    return 0;
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
    unsigned char *isint = NULL, *isfloat = NULL, *ismaybe = NULL;
    int any_maybe = 0;
    if (c->opt_int) {
        isint = calloc(pr->main_n_locals ? pr->main_n_locals : 1, 1);
        compute_int_slots(c, &pr->main_body, pr->main_n_locals, 0, pr->main_captured, isint, NULL);
        c->cur_is_int = isint;
        isfloat = calloc(pr->main_n_locals ? pr->main_n_locals : 1, 1);
        compute_float_slots(c, &pr->main_body, pr->main_n_locals, 0, pr->main_captured, isfloat, NULL);
        c->cur_is_float = isfloat;
        ismaybe = calloc(pr->main_n_locals ? pr->main_n_locals : 1, 1);
        any_maybe = compute_maybe_slots(c, &pr->main_body, pr->main_n_locals, 0, pr->main_captured, ismaybe);
    }
    c->cur_is_int = isint;
    c->cur_is_float = isfloat;
    c->cur_is_maybe = ismaybe;
    c->mt_depth = 0;
    c->mt_max = c->opt_int ? block_temp_need(c, &pr->main_body) : 0;
    (void)any_maybe;
    /* Pre-pass before locals: dispatch ids must be assigned so the
     * $next_BID i32 locals can be declared up-front. */
    c->next_label_id = 0;
    la_close_bases(&pr->main_body, 0);
    la_block(c, &pr->main_body, NULL);

    for (int i = 0; i < pr->main_n_locals; i++) {
        if (isint && isint[i]) {
            wat_appendf(out, "    (local $L%d i64)\n", i);
        } else if (isfloat && isfloat[i]) {
            wat_appendf(out, "    (local $L%d f64)\n", i);
        } else if (ismaybe && ismaybe[i]) {
            wat_appendf(out, "    (local $L%d anyref) (local $Lt%d i32) (local $Li%d i64) (local $Lf%d f64)\n",
                        i, i, i, i);
        } else if (pr->main_captured && pr->main_captured[i]) {
            wat_appendf(out, "    (local $L%d (ref $Box))\n", i);
        } else {
            wat_appendf(out, "    (local $L%d anyref)\n", i);
        }
    }
    for (int k = 0; k < c->mt_max; k++)
        wat_appendf(out, "    (local $mt%d anyref) (local $mg%d i32) (local $mi%d i64) (local $mf%d f64)\n",
                    k, k, k, k);
    wat_append(out, "    (local $tmp_any anyref)\n");
    wat_append(out, "    (local $tmp_args (ref null $ArgArr))\n");
    wat_append(out, "    (local $tmp_clo (ref null $LuaClosure))\n");
    wat_append(out, "    (local $tmp_callee anyref)\n");
    wat_append(out, "    (local $tmp_tab (ref null $LuaTable))\n");
    wat_append(out, "    (local $tmp_lhs_t (ref null $ArgArr))\n");
    wat_append(out, "    (local $tmp_lhs_k (ref null $ArgArr))\n");
    int main_n_close = count_fn_close(&pr->main_body);
    emit_tbc_locals(out, main_n_close > 0);
    emit_for_scratch_locals(out, &pr->main_body);
    if (c->opt_int) {
        int lv = max_for_nesting(&pr->main_body);
        for (int d = 0; d < lv; d++)
            wat_appendf(out, "    (local $ifor_stop_%d i64) (local $ifor_step_%d i64)"
                             " (local $ifor_next_%d i64)\n",
                        d, d, d);
    }
    {
        int bids[MAX_DISPATCH_IDS];
        int n = 0;
        collect_dispatch_ids(c, &pr->main_body, bids, &n, MAX_DISPATCH_IDS);
        for (int i = 0; i < n; i++) {
            wat_appendf(out, "    (local $next_%d i32)\n", bids[i]);
        }
    }
    if (!c->skip_runtime_init) wat_append(out, "    (call $stdlib_init)\n");
    /* Eager-init captured locals — see emit_user_function for the
     * rationale; main has no params, so every captured slot needs it. */
    for (int i = 0; i < pr->main_n_locals; i++) {
        if (pr->main_captured && pr->main_captured[i]) {
            wat_appendf(out,
                        "    (local.set $L%d (struct.new $Box (ref.null any)))\n", i);
        }
    }
    if (main_n_close > 0) emit_tbc_init(out, main_n_close);

    if (c->ok) emit_close_body(c, &pr->main_body, main_n_close > 0, 2);

    wat_append(out, "  )\n");
    c->cur_is_int = NULL;
    c->cur_is_float = NULL;
    c->cur_is_maybe = NULL;
    c->mt_max = 0;
    c->cur_func_slot = NULL;
    c->cur_upval_func = NULL;
    free(isint);
    free(isfloat);
    free(ismaybe);
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
            char tmp[2] = {(char)b, 0};
            wat_append(out, tmp);
        } else {
            wat_appendf(out, "\\%02x", b);
        }
    }
    wat_append(out, "\")\n");
}

/* The host-call ABI (codegen_module's embed_api): a small block of exported
 * thunks over the prelude's $lua_call / $tab_* and the value constructors, so
 * an embedder can build Lua values and tables, look up globals by name, and
 * invoke Lua functions from outside the module. A string's hash is cached
 * lazily on first use as a key, so lua_str_new + per-byte lua_str_setb writes
 * are safe as long as the string is filled before it is handed to Lua.
 * lua_call / lua_pcall go through $lua_call_any, so they accept any callable
 * (closure or a __call table) and set up the call frame error() reads; a
 * non-callable raises a normal Lua error. lua_call propagates Lua errors via
 * the exported $LuaError tag (like $main); lua_pcall catches them and returns
 * the Lua pcall convention [ok, ...]. Emitted only on request — it forces the
 * whole stdlib live (see codegen_module), which would otherwise defeat
 * live (see codegen_module), which would otherwise defeat tree-shaking. See
 * examples/embed and tests/test_embed_api. */
static void emit_embed_api(CG *c) {
    wat_append(
        c->w,
        "\n  ;; @@SECTION:embed-api@@\n"
        "  (func (export \"lua_str_new\") (param $n i32) (result anyref)\n"
        "    (struct.new $LuaString (array.new $LuaArr (i32.const 0) (local.get $n)) (i32.const 0)))\n"
        "  (func (export \"lua_str_setb\") (param $s anyref) (param $i i32) (param $b i32)\n"
        "    (array.set $LuaArr\n"
        "      (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $s)))\n"
        "      (local.get $i) (local.get $b)))\n"
        "  (func (export \"lua_get_global\") (param $name anyref) (result anyref)\n"
        "    (call $tab_get (ref.as_non_null (global.get $g_globals)) (local.get $name)))\n"
        "  (func (export \"lua_args_new\") (param $n i32) (result anyref)\n"
        "    (array.new $ArgArr (ref.null any) (local.get $n)))\n"
        "  (func (export \"lua_args_set\") (param $a anyref) (param $i i32) (param $v anyref)\n"
        "    (array.set $ArgArr (ref.cast (ref $ArgArr) (local.get $a)) (local.get $i)\n"
        "      (local.get $v)))\n"
        "  (func (export \"lua_args_get\") (param $a anyref) (param $i i32) (result anyref)\n"
        "    (array.get $ArgArr (ref.cast (ref $ArgArr) (local.get $a)) (local.get $i)))\n"
        "  (func (export \"lua_args_len\") (param $a anyref) (result i32)\n"
        "    (array.len (ref.cast (ref $ArgArr) (local.get $a))))\n"
        "  (func (export \"lua_call\") (param $fn anyref) (param $args anyref) (result anyref)\n"
        "    (call $lua_call_any (local.get $fn)\n"
        "                        (ref.cast (ref $ArgArr) (local.get $args)) (i32.const 0)))\n"
        /* Protected call: returns an ArgArr [ok_bool, ...results-or-error], the
         * Lua pcall convention, so the host never has to catch a wasm
         * exception. Restores $call_depth on a caught error (the throw leaves
         * the callee's frames un-popped) so later calls aren't corrupted. */
        "  (func (export \"lua_pcall\") (param $fn anyref) (param $args anyref) (result anyref)\n"
        "    (local $results (ref $ArgArr)) (local $r2 (ref $ArgArr))\n"
        "    (local $err anyref) (local $depth i32)\n"
        "    (local.set $depth (global.get $call_depth))\n"
        "    (block $caught (result anyref)\n"
        "      (local.set $results\n"
        "        (try_table (result (ref $ArgArr)) (catch $LuaError $caught)\n"
        "          (call $lua_call_any (local.get $fn)\n"
        "                              (ref.cast (ref $ArgArr) (local.get $args)) (i32.const 0))))\n"
        "      (local.set $r2 (array.new $ArgArr (ref.null any)\n"
        "        (i32.add (array.len (local.get $results)) (i32.const 1))))\n"
        "      (array.set $ArgArr (local.get $r2) (i32.const 0) (global.get $g_true))\n"
        "      (array.copy $ArgArr $ArgArr (local.get $r2) (i32.const 1)\n"
        "        (local.get $results) (i32.const 0) (array.len (local.get $results)))\n"
        "      (return (local.get $r2)))\n"
        "    (local.set $err)\n"
        "    (global.set $call_depth (local.get $depth))\n"
        "    (array.new_fixed $ArgArr 2 (global.get $g_false)\n"
        "      (call $err_or_noobj (local.get $err))))\n"
        /* Table marshaling: build/read/write Lua tables across the boundary.
         * Keys are ordinary Lua values (lua_make_int / lua_str_new). */
        "  (func (export \"lua_table_new\") (result anyref) (call $tab_new))\n"
        "  (func (export \"lua_table_get\") (param $t anyref) (param $k anyref) (result anyref)\n"
        "    (call $tab_get (ref.cast (ref $LuaTable) (local.get $t)) (local.get $k)))\n"
        "  (func (export \"lua_table_set\") (param $t anyref) (param $k anyref) (param $v anyref)\n"
        "    (call $tab_set (ref.cast (ref $LuaTable) (local.get $t)) (local.get $k) (local.get $v)))\n"
        "  (func (export \"lua_table_len\") (param $t anyref) (result i64)\n"
        "    (call $as_int (call $lua_len (local.get $t))))\n");
}

int codegen_module(const ParseResult *pr, const char *src_name,
                   int tree_shake, int opt, int embed_api, WatBuilder *out,
                   char *err, size_t errlen) {
    const char *slab_err = verify_literal_slab();
    if (slab_err) {
        snprintf(err, errlen,
                 "codegen: literal slab drift at \"%s\" — LITERAL_PREFIX and "
                 "the prelude.wat offset map disagree",
                 slab_err);
        return 0;
    }

    CG c = {.w = out, .pr = pr, .ok = 1, .in_main = 1};
    /* Numeric/call specialization is on by default (opt >= 1); -O0 selects the
     * boxed fallback. Behaviour is identical either way — only code shape and
     * speed differ — so goldens are shared across levels. */
    c.opt_int = opt >= 1;
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
        free(live);
        free(gref);
        return 0;
    }
    /* Always compute the referenced set — one walk also reports whether the
     * program is "globally closed" (no _G/_ENV/load/require escape) and whether
     * it observes any runtime state at all. When closed, the set is complete, so
     * dropping un-referenced builtins is behaviour-preserving and we tree-shake
     * by default; `--force-tree-shake` forces it even when not closed (which can
     * break dynamic _G lookups). When it observes no runtime state, $main skips
     * the eager $stdlib_init call (independent of opt; DCE then drops it). */
    int escaped = 0, needs_runtime = 0;
    compute_live_set(pr, nb, live, gref, &escaped, &needs_runtime);
    if (embed_api) {
        /* The host-call ABI reaches any global by name and invokes arbitrary
         * Lua functions, so the whole stdlib must stay live and $g_globals must
         * be populated. Force the program "open" (no tree-shake) and keep the
         * eager runtime init, regardless of what the chunk itself references. */
        escaped = 1;
        needs_runtime = 1;
        tree_shake = 0;
    }
    c.skip_runtime_init = !needs_runtime;
    int effective_tree_shake = tree_shake || !escaped;
    if (!effective_tree_shake) {
        for (int i = 0; i < nb; i++) live[i] = 1;
        for (size_t i = 0; i < pr->globals.count; i++) gref[i] = 1;
    }

    /* Route the stdlib bootstrap through the append-only $tab_bootstrap_set
     * only when it pays off: the program must write no tables of its own (else
     * the general write path stays live regardless) and tree-shake must be on
     * (otherwise every builtin — table.insert and friends — is kept, which
     * keeps the write path live too). See program_writes_table. */
    c.tab_set_fn =
        (effective_tree_shake && !program_writes_table(pr)) ? "$tab_bootstrap_set" : "$tab_set";

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
                    "    (struct.new $LuaClosure (ref.func %s) (global.get $g_empty_upvals) (i32.const 256)\n"
                    "      (ref.func $fast_adapter)))\n",
                    builtin_func_name(i) + 1, builtin_func_name(i));
    }

    /* User-declared globals used to get a per-name $g_user_N wasm slot.
     * Since milestone 19 they live as entries in $g_globals (the Lua _G
     * table) and access goes through $tab_get / $tab_set. The parser
     * still tracks the global list for name resolution, but no wasm
     * globals are emitted for them. */

    /* Metamethod-name key globals (see MKEYS). */
    for (size_t k = 0; k < N_MKEYS; k++)
        emit_global_const_str(&c, MKEYS[k].name, MKEYS[k].key, strlen(MKEYS[k].key));
    /* The empty string and the source name (used by error()/traceback) are also
     * constants — const-init them so DCE can drop them when unreferenced. */
    emit_global_const_str(&c, "$g_empty_str", "", 0);
    emit_global_const_str(&c, "$g_src_name", src_name ? src_name : "", src_name ? strlen(src_name) : 0);

    /* $stdlib_init: builds math/string tables from the library builtins
     * and assigns them to the corresponding $g_user_N slots. */
    wat_append(out, "\n  (func $stdlib_init"
                    " (local $tab (ref $LuaTable))"
                    " (local $h (ref $LuaTable))\n");
    wat_appendf(out,
                "    (global.set $fmt_buf\n"
                "      (array.new $LuaArr (i32.const 0) (i32.const %d)))\n"
                "    (global.set $call_lines\n"
                "      (array.new $LineArr (i32.const 0) (i32.const 256)))\n"
                "    (global.set $call_weights\n"
                "      (array.new $LineArr (i32.const 0) (i32.const 256)))\n",
                LUA_FMT_BUF_CAP);
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
        if (key[0] == '_') continue; /* internal-only (e.g. _ipairs_iter) */
        char val[128];
        int vn = snprintf(val, sizeof(val), "(global.get $g_%s)",
                          builtin_func_name(bi) + 1);
        if (vn < 0 || (size_t)vn >= sizeof(val)) {
            cg_error(&c, "builtin global-get expression too long");
            break;
        }
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
        emit_user_function(&c, pr->funcs.items[i], ENTRY_GENERIC);
        if (fn_has_fast_entry(&c, pr->funcs.items[i])) emit_user_function(&c, pr->funcs.items[i], ENTRY_FAST);
        /* Direct-call fast entries (non-vararg only): _da returns the result
         * array (multi-value call contexts), _da1 returns a single value
         * (single-value contexts — no result-array allocation). Emitted only
         * when some direct-call site actually targets this function (has_site),
         * otherwise they would be dead code. */
        if (c.opt_int && !pr->funcs.items[i]->is_vararg && c.sigs[i].has_site) {
            emit_user_function(&c, pr->funcs.items[i], ENTRY_DIRECT);
            emit_user_function(&c, pr->funcs.items[i], ENTRY_DIRECT1);
        }
        if (!c.ok) break;
    }

    if (c.ok) emit_main_chunk(&c);

    if (c.ok && embed_api) emit_embed_api(&c);

    emit_kstr_globals(&c);
    for (int i = 0; i < c.n_ctor_shapes; i++)
        wat_appendf(out, "  (global $cshape_%d (mut (ref null $Shape)) (ref.null $Shape))\n", i);
    for (int i = 0; i < c.n_ics; i++)
        wat_appendf(out, "  (global $ic_%d (ref $IC) (struct.new $IC (ref.null $Shape) (i32.const 0)))\n", i);
    for (int i = 0; i < c.n_mics; i++)
        wat_appendf(out,
                    "  (global $mic_%d (ref $MIC) (struct.new $MIC (ref.null $Shape) (ref.null $Shape) (i32.const 0)"
                    " (ref.null $LuaTable) (ref.null $Shape) (i32.const 0)))\n",
                    i);
    emit_data_segment(&c);

    wat_append(out, ")\n");

    if (!c.ok) {
        snprintf(err, errlen, "%s", c.err);
        strpool_free(&c.strs);
        strpool_free(&c.kstrs);
        free(c.kstr_list);
        free(live);
        free(gref);
        free_func_bindings(&c);
        free_signatures(&c);
        return 0;
    }
    strpool_free(&c.strs);
    strpool_free(&c.kstrs);
    free(c.kstr_list);
    free(live);
    free(gref);
    free_func_bindings(&c);
    free_signatures(&c);
    return 1;
}
