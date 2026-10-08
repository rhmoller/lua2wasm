/* Internal interface of the code generator: the codegen context (CG), the types the
 * src/codegen/ modules share, and each module's entry points. */
#ifndef LUA2WASM_CODEGEN_INTERNAL_H
#define LUA2WASM_CODEGEN_INTERNAL_H

#include "../builtins.h"
#include "../codegen.h"
#include "../xalloc.h"
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================
 * The code generator.
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

/* Nested loop break targets the codegen tracks. Exceeding it raises a codegen
 * error at the loop (never silently truncates); so do the per-block label and
 * per-function dispatch caps in stmt.c. */
#define MAX_BREAK_DEPTH 64

/* ----- constant strings (strings.c) ----- */

/* One slot of StrPool's run index. */
typedef struct {
    size_t hash;   /* FNV-1a of the run's bytes (run hashed at insert time) */
    size_t offset; /* its resolved offset in the byte array */
    size_t len;    /* its length, for collision verification */
    int used;      /* slot occupied */
} StrIdxSlot;

/* Interned bytes, deduplicated: a run already present anywhere in the pool,
 * even inside a longer one, resolves to its existing offset. */
typedef struct {
    char *bytes;
    size_t used;
    size_t cap;
    StrIdxSlot *idx;  /* open-addressing index; NULL until first insert */
    size_t idx_cap;   /* power-of-two capacity */
    size_t idx_count; /* occupied slots */
} StrPool;

/* An interned run: where its bytes sit in the pool. */
typedef struct {
    size_t offset;
    size_t len;
} StrRef;

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
    /* Direct calls: cur_func_slot[s] != NULL means local slot s is statically
     * bound to that LuaFunc (its row of bind_slot, below), so a call f(args) of
     * matching arity can skip the $ArgArr and invoke one of the function's
     * direct entries ($user_N_da / _da1). */
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
    /* The body being emitted (body_begin .. body_end). */
    const struct Body *cur_body;
    /* Run-once loop outlining (outline.c). While the function of an outlined
     * loop is emitted, ol_active is set and ol_loop is that loop: it resumes
     * and suspends, the loops inside it count down the chunk budget, and a
     * `return` hands its value to the caller. The finished functions wait in
     * ol_pending until the enclosing function is complete. */
    const Stmt *ol_loop;
    int ol_active;
    int n_outlined; /* $ol_N functions so far */
    WatBuilder ol_pending;
    unsigned char *run_once; /* by func_idx: the function provably runs at most once */
    /* Int boxes (analysis.c, compute_ibox): captured locals held in an $IBox,
     * by slot — ibox_fn[func_idx] for a function, ibox_main for the main
     * chunk. NULL until computed (signature inference runs without them). */
    unsigned char **ibox_fn;
    unsigned char *ibox_main;
    int n_ibox_fn;
    char err[256];
    int ok;
} CG;

/* A function body being compiled — one wasm entry of a Lua function, or the
 * main chunk (see body_begin in stmt.c). */
typedef struct Body {
    const Block *body;
    int n_locals, n_params;
    const unsigned char *captured;            /* escape analysis: slots held in a $Box */
    int func_idx;                             /* -1 for the main chunk */
    const LuaFunc **func_slot, **upval_func;  /* direct-call binding maps */
    unsigned char *isint, *isfloat, *ismaybe; /* slot analyses (NULL at -O0) */
    const unsigned char *ibox;                /* captured slots held in an $IBox (NULL: none) */
    int n_close;                              /* to-be-closed locals */
    int is_vararg;
    int outline; /* runs once: its outermost loops become resumable functions (outline.c) */
} Body;

/* How a body keeps local slot i: the wasm local(s) body_declare_locals gives it. */
typedef enum {
    REP_ANY,   /* $L<i> anyref */
    REP_BOX,   /* $L<i> (ref $Box): captured by a closure */
    REP_IBOX,  /* $L<i> (ref $IBox): captured, and only ever an integer */
    REP_I64,   /* $L<i> i64: integer-typed */
    REP_F64,   /* $L<i> f64: float-typed */
    REP_MAYBE, /* $L<i> anyref + $Lt<i> i32 + $Li<i> i64 + $Lf<i> f64 */
} SlotRep;
static inline SlotRep slot_rep(const Body *b, int i) {
    if (b->isint && b->isint[i]) return REP_I64;
    if (b->isfloat && b->isfloat[i]) return REP_F64;
    if (b->ismaybe && b->ismaybe[i]) return REP_MAYBE;
    if (b->ibox && b->ibox[i]) return REP_IBOX;
    if (b->captured && b->captured[i]) return REP_BOX;
    return REP_ANY;
}

/* What a captured slot holds until its declaration runs: the validator wants
 * a set before every get of a non-nullable local. */
static inline const char *box_placeholder(const Body *b, int i) {
    return slot_rep(b, i) == REP_IBOX ? "(struct.new $IBox (ref.null any) (i64.const 0))"
                                      : "(struct.new $Box (ref.null any))";
}

/* A cell is the four-part view of a maybe value used by the lowering: read
 * expressions for tag / i64 / f64 / boxed, plus the local names to write when
 * the cell is a destination (a slot or a temporary). An *immediate* cell has
 * no write targets: a numeric literal, or a provably typed local, appears in
 * the tag switch as constants / a plain local.get and costs no temporary. */
typedef struct {
    char t[48], i[48], f[48], b[48];     /* read expressions */
    char st[16], si[16], sf[16], sb[16]; /* write targets ("" for an immediate) */
    int static_tag;                      /* an immediate's tag; 0 when known only at run time */
} MCell;

/* A cell's tag: which part holds the value. The prelude's $unbox_num and
 * $box_num use the same encoding. */
enum { TAG_BOXED = 0, /* not a number: the anyref */
       TAG_INT = 1,
       TAG_FLOAT = 2 };

/* Longest constant string that is hoisted into a module global; longer
 * literals are allocated from $str_data at each evaluation. Bounded so an
 * array.new_fixed initializer never approaches engine operand limits. */
#define KSTR_MAX 256

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

/* Visitors for the statement traversal (analysis.c). */
typedef void (*BlockVisit)(const Block *b, void *ctx);
typedef void (*StmtVisit)(const Stmt *s, void *ctx);
typedef void (*ExprVisit)(const Expr *e, void *ctx);

/* The math builtins a lowered tree can inline (maybe.c). */
typedef enum { MB_NONE = 0,
               MB_SQRT,
               MB_ABS,
               MB_FLOOR,
               MB_CEIL } MathBuiltin;

/* ----- helpers every module uses ----- */

static inline int stmt_is_loop(const Stmt *s) {
    return s->kind == STMT_WHILE || s->kind == STMT_REPEAT || s->kind == STMT_FOR_NUM || s->kind == STMT_FOR_GEN;
}

/* True iff the local at this slot index must be allocated as a $Box. */
static inline int slot_is_boxed(const CG *c, int slot) {
    if (slot < 0 || slot >= c->cur_n_locals) return 1; /* defensive */
    return c->cur_captured ? c->cur_captured[slot] : 1;
}

static inline void cg_error(CG *c, const char *msg) {
    if (!c->ok) return;
    c->ok = 0;
    snprintf(c->err, sizeof(c->err), "codegen: %s", msg);
}

static inline void emit_indent(CG *c, int depth) {
    for (int i = 0; i < depth; i++) wat_append(c->w, "  ");
}

/* One line of WAT at `depth`: the indentation, then `text` (which carries
 * its own trailing newline, if any). */
static inline void emit_line(CG *c, int depth, const char *text) {
    emit_indent(c, depth);
    wat_append(c->w, text);
}

/* printf-style emit_line. */
[[gnu::format(printf, 3, 4)]] static inline void emit_linef(CG *c, int depth, const char *fmt, ...) {
    va_list ap;
    emit_indent(c, depth);
    va_start(ap, fmt);
    wat_vappendf(c->w, fmt, ap);
    va_end(ap);
}

static inline int i31_fits(int64_t v) {
    return v >= -(int64_t)0x40000000 && v < (int64_t)0x40000000;
}

/* ----- strings.c ----- */
StrRef strpool_add(StrPool *p, const char *bytes, size_t len);
void strpool_free(StrPool *p);
int32_t kstr_hash(const char *bytes, size_t len);
const char *kstr_expr(CG *c, const char *bytes, size_t len, char *buf, size_t bufsz);
void emit_global_const_str(CG *c, const char *glob, const char *s, size_t len);
void emit_kstr_globals(CG *c);
void emit_mkey_globals(CG *c);

/* ----- analysis.c ----- */
void for_each_nested_block(const Stmt *s, BlockVisit fn, void *ctx);
void walk_stmts(const Block *b, StmtVisit fn, void *ctx);
void for_each_own_expr(const Stmt *s, ExprVisit fn, void *ctx);
void for_each_subexpr(const Expr *e, ExprVisit fn, void *ctx);
int slot_is_int(const CG *c, int slot);
int expr_is_int(CG *c, const Expr *e);
int slot_is_float(const CG *c, int slot);
int expr_is_float(CG *c, const Expr *e);
void compute_int_slots(CG *c, const Block *body, int n_locals, int n_params,
                       const unsigned char *captured, unsigned char *out,
                       const NumTy *param_seed);
void compute_float_slots(CG *c, const Block *body, int n_locals, int n_params,
                         const unsigned char *captured, unsigned char *out,
                         const NumTy *param_seed);
int maybe_arith_op(BinOp op);
int slot_is_maybe(const CG *c, int slot);
int expr_involves_maybe(CG *c, const Expr *e);
int operand_immediate(CG *c, const Expr *e, const Expr *other_after, MCell *out);
int block_temp_need(CG *c, const Block *b);
void compute_maybe_slots(CG *c, const Block *body, int n_locals, int n_params,
                         const unsigned char *captured, unsigned char *out);
void resolve_upval_origin(CG *c, int func_idx, int u, int *of, int *os);
void compute_func_bindings(CG *c, const ParseResult *pr);
void free_func_bindings(CG *c);
void infer_signatures(CG *c, const ParseResult *pr);
void free_signatures(CG *c);
const unsigned char *ibox_row(const CG *c, int func_idx);
int slot_is_ibox(const CG *c, int slot);
int upval_is_ibox(CG *c, int u);
int ibox_init(CG *c, const ParseResult *pr);
int ibox_settle(CG *c, const ParseResult *pr);
void free_ibox(CG *c);

/* ----- expr.c ----- */
const char *ic_new(CG *c, char *buf, size_t bufsz);
void emit_string_literal(CG *c, const char *bytes, size_t len, int depth);
void emit_global_key(CG *c, const char *name, size_t name_len);
void emit_target_open(CG *c, const AssignTarget *t, int depth);
void emit_target_close(CG *c, const AssignTarget *t, int depth);
void emit_ibox_ref(CG *c, VarKind kind, int idx);
const char *binop_helper(BinOp op);
int is_cmp_op(BinOp op);
const CmpOp *cmp_op(BinOp op);
int expr_is_exact_f64_int_literal(const Expr *e);
void emit_truthy(CG *c, const Expr *e, int depth);
int is_multival_tail(const Expr *e);
void emit_multival_array(CG *c, const Expr *e, int depth);
const LuaFunc *direct_call_target(CG *c, const Expr *e);
const FuncSig *target_sig(CG *c, const LuaFunc *K);
NumTy expr_num_ty(CG *c, const Expr *e);
int direct_args_typed_ok(CG *c, const Expr *e, const LuaFunc *K);
void emit_typed_direct_call1(CG *c, const Expr *e, const LuaFunc *K, int depth);
int fn_has_fast_entry(const CG *c, const LuaFunc *fn);
int fast_call_nargs(const CG *c, const Expr *e);
void emit_args_array(CG *c, Expr **args, size_t nargs, int depth);
void emit_call_array(CG *c, const Expr *e, int depth);
void emit_fast_call(CG *c, const Expr *e, int depth);
void emit_tail_call(CG *c, const Expr *e, int depth);
void emit_fast_tail_call(CG *c, const Expr *e, int depth);
void emit_function_expr(CG *c, const LuaFunc *fn, int depth);
void emit_int_expr(CG *c, const Expr *e, int depth);
void emit_num_as_f64(CG *c, const Expr *e, int depth);
void emit_float_expr(CG *c, const Expr *e, int depth);
void emit_expr(CG *c, const Expr *e, int depth);
void emit_args_at(CG *c, int idx, int depth);

/* ----- maybe.c ----- */
MCell mcell_slot(int s);
MCell mcell_tmp(int k);
MCell mcell_imm_int(int64_t v);
MCell mcell_imm_float(double v);
MCell mcell_typed_local(int slot, int is_float);
int mt_alloc(CG *c, int n);
void emit_set_tag(CG *c, const MCell *m, int tag, int depth);
void emit_maybe_slot_box(CG *c, int slot, int depth);
MathBuiltin callee_math_kind(CG *c, const Expr *callee);
void emit_maybe_lower(CG *c, const Expr *e, const MCell *d, int depth);
void emit_maybe_store(CG *c, int slot, const Expr *e, int depth);
void emit_maybe_boxed(CG *c, const Expr *e, int depth);
void emit_maybe_cmp_block(CG *c, const Expr *e, int depth);

/* ----- stmt.c ----- */
void emit_stmt(CG *c, const Stmt *s, int depth);
Body function_body(const CG *c, const LuaFunc *fn);
void body_begin(CG *c, Body *b, const NumTy *param_seed);
void body_declare_locals(CG *c, const Body *b, int fast, int vararg);
void body_declare_locals_of(CG *c, const Body *b, const unsigned char *slots, int fast, int vararg);
void body_emit(CG *c, const Body *b);
void body_end(CG *c, Body *b);

/* ----- outline.c ----- */
/* What a call to an outlined loop's function reports. */
enum { OL_START = 0,     /* (passed in) the first call: run the loop's setup */
       OL_SUSPENDED = 1, /* the budget ran out: call again to carry on */
       OL_DONE = 2,      /* the loop finished (or broke out) */
       OL_RETURN = 3 };  /* a `return` inside it: return the value it handed back */
int body_runs_once(const CG *c, const Body *b);
void compute_run_once(CG *c, const ParseResult *pr);
const char *ol_ret_type(const CG *c);
int emit_outlined_loop(CG *c, const Stmt *s, int depth);
void ol_loop_header(CG *c, const Stmt *s, int depth);
void ol_init_open(CG *c, const Stmt *s, int depth);
void ol_init_close(CG *c, const Stmt *s, int depth);
void ol_flush(CG *c);

/* ----- arrays.c ----- */
/* An integer key for the inline array-part paths: an i64 read (`i`), or a
 * maybe cell (`cell`) whose int tag the path checks first. */
typedef struct {
    const char *i;
    const MCell *cell;
} IxKey;
void emit_ix_locals(WatBuilder *w);
int emit_ix_get_open(CG *c, int depth);
void emit_ix_get_close(CG *c, int n, const MCell *cell, int line, int depth);
void emit_ix_get_cell(CG *c, const MCell *cell, const MCell *d, int line, int depth);
void emit_ix_set(CG *c, const char *tb, IxKey k, const char *v, int depth);
void emit_ix_set_f(CG *c, const char *tb, const char *ki, const char *f, int depth);

/* ----- module.c ----- */
const char *slab_ref(const char *text);
int fn_frame_weight(CG *c, const LuaFunc *fn);

#endif
