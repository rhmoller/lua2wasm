/* Run-once loop outlining.
 *
 * V8 has no on-stack replacement for wasm: a function starts on the baseline
 * tier (Liftoff) and is switched to optimized code only for its *next* call,
 * once it has run hot. A loop in code that runs once — the main chunk, or a
 * function the main chunk calls once — therefore runs on baseline code for
 * its whole life, at about half the speed of the same loop in a function
 * that is called repeatedly (docs/design/24-run-once-loops.md).
 *
 * So each outermost loop of a run-once body becomes a function of its own,
 * $ol_N, that runs the loop for a budget of iterations (those of the loops
 * inside it included) and then returns everything the loop needs to carry on:
 * the enclosing body's locals that the loop uses, and the loop's own control
 * state (a numeric for's counter, limit and step; a generic for's iterator,
 * state and control value). The caller calls it again until it reports that
 * the loop is done; each call is a chance for the engine to switch to the
 * optimized code.
 *
 * A loop suspends at its header — before a while's condition, a repeat's
 * body, a numeric for's exit test, a generic for's iterator call — where
 * nothing of the next iteration has run, so suspending and resuming is
 * unobservable. A `return` inside the loop leaves with OL_RETURN and the
 * returned value, which the caller returns. A loop with a `goto` to a label
 * outside it stays inline. */
#include "internal.h"

/* Iterations (of the outlined loop and the loops inside it) per call. Large
 * enough that the calls cost nothing measurable, small enough that the
 * engine's switch to optimized code takes effect within a fraction of a
 * millisecond. Tests set it to 1, so every iteration suspends and resumes. */
int codegen_loop_chunk = 1 << 16;

/* The most wasm values a loop's state may take; beyond it, the loop stays
 * inline (engines cap a function's parameters and results at 1000). */
#define OL_MAX_STATE 400

/* Is there a loop in b outside any other loop (inside an if or do block
 * counts)? */
static int has_outer_loop(const Block *b);
static void has_outer_loop_in(const Block *b, void *found) {
    if (has_outer_loop(b)) *(int *)found = 1;
}
static int has_outer_loop(const Block *b) {
    for (size_t i = 0; i < b->count; i++) {
        if (stmt_is_loop(b->items[i])) return 1;
        int found = 0;
        for_each_nested_block(b->items[i], has_outer_loop_in, &found);
        if (found) return 1;
    }
    return 0;
}

/* Does the body run once, with a loop to outline? (Asked before the body is
 * emitted: the caller's side of the protocol declares locals.) */
int body_runs_once(const CG *c, const Body *b) {
    if (!c->opt_int || codegen_loop_chunk <= 0) return 0;
    int once = b->func_idx < 0 || (c->run_once && c->run_once[b->func_idx]);
    return once && has_outer_loop(b->body);
}

/* ----- functions that run once -----
 * A function bound to a main-chunk local runs at most once when the local is
 * never reassigned (it has a binding), no closure captures it (so no other
 * function, the function itself included, can reach it), and the main chunk
 * mentions it exactly once: as the callee of a call outside any loop. A main
 * chunk with a goto is left alone — a backward goto is a loop too. */
typedef struct {
    int *uses, *calls; /* per main slot: references; calls outside loops */
    int n, loops, has_goto;
} OnceScan;

static void once_expr(const Expr *e, void *ctx) {
    OnceScan *o = ctx;
    if (e->kind == EXPR_VAR && e->as.var.kind == VAR_LOCAL && e->as.var.idx >= 0 && e->as.var.idx < o->n)
        o->uses[e->as.var.idx]++;
    if (e->kind == EXPR_CALL && o->loops == 0) {
        const Expr *f = e->as.call.callee;
        if (f->kind == EXPR_VAR && f->as.var.kind == VAR_LOCAL && f->as.var.idx >= 0 && f->as.var.idx < o->n)
            o->calls[f->as.var.idx]++;
    }
    for_each_subexpr(e, once_expr, o);
}
static void once_block(const Block *b, void *ctx);
static void once_stmt(const Stmt *s, OnceScan *o) {
    int loop = stmt_is_loop(s);
    if (s->kind == STMT_GOTO) o->has_goto = 1;
    o->loops += loop; /* a loop's own expressions count as inside it */
    for_each_own_expr(s, once_expr, o);
    for_each_nested_block(s, once_block, o);
    o->loops -= loop;
}
static void once_block(const Block *b, void *ctx) {
    for (size_t i = 0; i < b->count; i++) once_stmt(b->items[i], ctx);
}

void compute_run_once(CG *c, const ParseResult *pr) {
    c->run_once = xcalloc(pr->funcs.count, 1);
    if (!c->main_slot_func) return;
    int n = pr->main_n_locals;
    OnceScan o = {.uses = xcalloc((size_t)n, sizeof(int)), .calls = xcalloc((size_t)n, sizeof(int)), .n = n};
    once_block(&pr->main_body, &o);
    for (int s = 0; s < n && !o.has_goto; s++) {
        const LuaFunc *fn = c->main_slot_func[s];
        if (fn && !(pr->main_captured && pr->main_captured[s]) && o.uses[s] == 1 && o.calls[s] == 1)
            c->run_once[fn->func_idx] = 1;
    }
    free(o.uses);
    free(o.calls);
}

/* The type of what a `return` inside an outlined loop hands back: the value
 * the enclosing entry returns, or NULL in the main chunk (it returns none). */
const char *ol_ret_type(const CG *c) {
    if (c->in_main) return NULL;
    if (c->entry == ENTRY_DIRECT1 || c->entry == ENTRY_FAST)
        return c->cur_ret_ty == NT_INT ? "i64" : c->cur_ret_ty == NT_FLOAT ? "f64"
                                                                           : "anyref";
    return "(ref null $ArgArr)";
}

/* ----- what the loop touches ----- */

typedef struct {
    unsigned char *ref;     /* slots the loop reads, writes, declares or captures */
    unsigned char *decl;    /* slots declared inside the loop */
    unsigned char *labels;  /* dispatch ids of the label blocks inside the loop */
    unsigned char *targets; /* dispatch ids its gotos jump to */
    int n_slots, n_ids;
    int has_return;
} LoopScan;

static void scan_slot(LoopScan *sc, int slot, int declared) {
    if (slot < 0 || slot >= sc->n_slots) return;
    sc->ref[slot] = 1;
    if (declared) sc->decl[slot] = 1;
}

/* A closure created inside the loop captures the boxes of these slots. */
static void scan_captures(LoopScan *sc, const LuaFunc *fn) {
    for (int i = 0; i < fn->n_upvalues; i++)
        if (fn->upvalues[i].src == UPVAL_FROM_LOCAL) scan_slot(sc, fn->upvalues[i].idx, 0);
}

static void scan_expr(const Expr *e, void *ctx) {
    LoopScan *sc = ctx;
    if (e->kind == EXPR_VAR && e->as.var.kind == VAR_LOCAL) scan_slot(sc, e->as.var.idx, 0);
    if (e->kind == EXPR_FUNCTION) scan_captures(sc, e->as.func_expr.func);
    for_each_subexpr(e, scan_expr, sc);
}

static void scan_stmt(const Stmt *s, void *ctx) {
    LoopScan *sc = ctx;
    switch (s->kind) {
    case STMT_LOCAL:
        for (int i = 0; i < s->as.local.n_names; i++) scan_slot(sc, s->as.local.local_idxs[i], 1);
        break;
    case STMT_ASSIGN:
        for (int i = 0; i < s->as.assign.n_targets; i++) {
            const AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind == TGT_VAR && t->as.var.kind == VAR_LOCAL) scan_slot(sc, t->as.var.idx, 0);
        }
        break;
    case STMT_LOCAL_FUNC:
        scan_slot(sc, s->as.local_func.local_idx, 1);
        scan_captures(sc, s->as.local_func.func);
        break;
    case STMT_FOR_NUM: scan_slot(sc, s->as.for_num.local_idx, 1); break;
    case STMT_FOR_GEN:
        for (int i = 0; i < s->as.for_gen.n_names; i++) scan_slot(sc, s->as.for_gen.local_idxs[i], 1);
        break;
    case STMT_RETURN: sc->has_return = 1; break;
    case STMT_LABEL:
    case STMT_GOTO: {
        int id = s->as.label.block_dispatch_id;
        if (id >= 0 && id < sc->n_ids) (s->kind == STMT_LABEL ? sc->labels : sc->targets)[id] = 1;
        break;
    }
    default: break;
    }
    for_each_own_expr(s, scan_expr, sc);
}

static void scan_block(const Block *b, void *ctx) { walk_stmts(b, scan_stmt, ctx); }

/* Scan loop s; returns 0 when it can't be outlined (a goto leaves it). */
static int scan_loop(CG *c, const Stmt *s, LoopScan *sc) {
    *sc = (LoopScan){.n_slots = c->cur_body->n_locals, .n_ids = c->next_label_id};
    sc->ref = xcalloc((size_t)sc->n_slots, 1);
    sc->decl = xcalloc((size_t)sc->n_slots, 1);
    sc->labels = xcalloc((size_t)sc->n_ids, 1);
    sc->targets = xcalloc((size_t)sc->n_ids, 1);
    scan_stmt(s, sc);
    for_each_nested_block(s, scan_block, sc);
    for (int id = 0; id < sc->n_ids; id++)
        if (sc->targets[id] && !sc->labels[id]) return 0;
    return 1;
}

static void scan_free(LoopScan *sc) {
    free(sc->ref);
    free(sc->decl);
    free(sc->labels);
    free(sc->targets);
}

/* ----- the loop's state ----- */

typedef struct {
    char name[24];
    const char *type;
} OlVar;

typedef struct {
    OlVar v[OL_MAX_STATE];
    int n, overflow;
} OlState;

[[gnu::format(printf, 3, 4)]] static void state_add(OlState *st, const char *type, const char *fmt, ...) {
    if (st->n == OL_MAX_STATE) {
        st->overflow = 1;
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(st->v[st->n].name, sizeof st->v[st->n].name, fmt, ap);
    va_end(ap);
    st->v[st->n++].type = type;
}

/* The wasm local(s) holding slot i (see body_declare_locals). */
static void state_add_slot(OlState *st, const Body *b, int i) {
    switch (slot_rep(b, i)) {
    case REP_I64: state_add(st, "i64", "$L%d", i); break;
    case REP_F64: state_add(st, "f64", "$L%d", i); break;
    case REP_BOX: state_add(st, "(ref $Box)", "$L%d", i); break;
    case REP_IBOX: state_add(st, "(ref $IBox)", "$L%d", i); break;
    case REP_ANY: state_add(st, "anyref", "$L%d", i); break;
    case REP_MAYBE:
        state_add(st, "anyref", "$L%d", i);
        state_add(st, "i32", "$Lt%d", i);
        state_add(st, "i64", "$Li%d", i);
        state_add(st, "f64", "$Lf%d", i);
        break;
    }
}

/* Everything that carries over from one call to the next: the enclosing
 * body's locals the loop uses, then the loop's own control state at for-loop
 * level fd (the locals its emitter keeps it in). */
static void loop_state(CG *c, const Stmt *s, const LoopScan *sc, OlState *st) {
    const Body *b = c->cur_body;
    int fd = c->for_depth;
    for (int i = 0; i < sc->n_slots; i++)
        if (sc->ref[i] && !sc->decl[i]) state_add_slot(st, b, i);
    if (s->kind == STMT_FOR_NUM) {
        int slot = s->as.for_num.local_idx;
        if (slot_is_int(c, slot)) {
            state_add_slot(st, b, slot);
            state_add(st, "i64", "$ifor_stop_%d", fd);
            state_add(st, "i64", "$ifor_step_%d", fd);
        } else {
            if (slot_is_boxed(c, slot)) state_add(st, "anyref", "$for_cur_%d", fd);
            else state_add_slot(st, b, slot);
            state_add(st, "anyref", "$for_stop_%d", fd);
            state_add(st, "anyref", "$for_step_%d", fd);
        }
    } else if (s->kind == STMT_FOR_GEN) {
        state_add(st, "anyref", "$for_iter_%d", fd);
        state_add(st, "anyref", "$for_state_%d", fd);
        state_add(st, "anyref", "$for_k_%d", fd);
        state_add(st, "i32", "$for_mode_%d", fd);
        state_add(st, "i64", "$for_pos_%d", fd);
    }
}

/* ----- emission ----- */

/* The loop's function: `(func $ol_N (param resume, state..., extras) (result
 * status, state..., [returned value])`. The state comes in through $olp<i>
 * and lives in the same locals the enclosing body uses, so the loop's code is
 * emitted exactly as it would be inline. */
static void emit_loop_function(CG *c, const Stmt *s, int id, const LoopScan *sc, const OlState *st,
                               const char *rt, int pass_closure, int pass_varargs, int pass_tbc) {
    const Body *b = c->cur_body;
    WatBuilder *w = c->w;
    wat_appendf(w, "  (func $ol_%d (param $olp_resume i32)", id);
    for (int i = 0; i < st->n; i++) wat_appendf(w, " (param $olp%d %s)", i, st->v[i].type);
    if (pass_closure) wat_append(w, " (param $closure (ref $LuaClosure))");
    if (pass_varargs) wat_append(w, " (param $olp_varargs (ref $ArgArr))");
    if (pass_tbc) wat_append(w, " (param $olp_tbc (ref null $Tbc))");
    wat_append(w, " (result i32");
    for (int i = 0; i < st->n; i++) wat_appendf(w, " %s", st->v[i].type);
    if (rt) wat_appendf(w, " %s", rt);
    wat_append(w, ")\n");

    body_declare_locals_of(c, b, sc->ref, 0, pass_varargs);
    wat_append(w, "    (local $ol_budget i32) (local $ol_status i32)\n");
    if (rt) wat_appendf(w, "    (local $ol_ret %s)\n", rt);

    /* A placeholder box for each captured local the loop declares (the
     * validator wants a set before every get; see body_emit), then the
     * state. */
    for (int i = 0; i < sc->n_slots; i++)
        if (sc->decl[i] && (slot_rep(b, i) == REP_BOX || slot_rep(b, i) == REP_IBOX))
            wat_appendf(w, "    (local.set $L%d %s)\n", i, box_placeholder(b, i));
    for (int i = 0; i < st->n; i++) wat_appendf(w, "    (local.set %s (local.get $olp%d))\n", st->v[i].name, i);
    if (pass_varargs) wat_append(w, "    (local.set $varargs (local.get $olp_varargs))\n");
    if (pass_tbc) wat_append(w, "    (local.set $tbc (local.get $olp_tbc))\n");
    wat_appendf(w, "    (local.set $ol_budget (i32.const %d))\n", codegen_loop_chunk);

    wat_append(w, "    (block $ol_exit\n"
                  "      (block $ol_suspend\n");
    c->ol_active = 1;
    c->ol_loop = s;
    emit_stmt(c, s, 4);
    c->ol_active = 0;
    c->ol_loop = NULL;
    wat_appendf(w,
                "        (local.set $ol_status (i32.const %d))\n"
                "        (br $ol_exit))\n"
                "      (local.set $ol_status (i32.const %d)))\n",
                OL_DONE, OL_SUSPENDED);
    wat_append(w, "    (local.get $ol_status)");
    for (int i = 0; i < st->n; i++) wat_appendf(w, " (local.get %s)", st->v[i].name);
    if (rt) wat_append(w, " (local.get $ol_ret)");
    wat_append(w, "\n  )\n");
}

/* The caller's side: call $ol_N until it is done, then return what a
 * `return` inside the loop returned. */
static void emit_loop_call(CG *c, int id, const OlState *st, const char *rt, int pass_closure,
                           int pass_varargs, int pass_tbc, int has_return, int depth) {
    emit_linef(c, depth, "(local.set $olc_st (i32.const %d))\n", OL_START);
    emit_linef(c, depth, "(loop $ol_again_%d\n", id);
    emit_linef(c, depth + 1, "(call $ol_%d (local.get $olc_st)", id);
    for (int i = 0; i < st->n; i++) wat_appendf(c->w, " (local.get %s)", st->v[i].name);
    if (pass_closure) wat_append(c->w, " (local.get $closure)");
    if (pass_varargs) wat_append(c->w, " (local.get $varargs)");
    if (pass_tbc) wat_append(c->w, " (local.get $tbc)");
    wat_append(c->w, ")\n");
    if (rt) emit_line(c, depth + 1, "(local.set $olc_ret)\n");
    for (int i = st->n - 1; i >= 0; i--) emit_linef(c, depth + 1, "(local.set %s)\n", st->v[i].name);
    emit_line(c, depth + 1, "(local.set $olc_st)\n");
    emit_linef(c, depth + 1, "(br_if $ol_again_%d (i32.eq (local.get $olc_st) (i32.const %d))))\n", id,
               OL_SUSPENDED);
    if (!has_return) return;
    emit_linef(c, depth, "(if (i32.eq (local.get $olc_st) (i32.const %d))\n", OL_RETURN);
    if (!rt) emit_line(c, depth + 1, "(then (return)))\n");
    else if (rt[0] == '(') emit_line(c, depth + 1, "(then (return (ref.as_non_null (local.get $olc_ret)))))\n");
    else emit_line(c, depth + 1, "(then (return (local.get $olc_ret))))\n");
}

int emit_outlined_loop(CG *c, const Stmt *s, int depth) {
    const Body *b = c->cur_body;
    if (!b || !b->outline || c->ol_active || c->break_depth != 0) return 0;
    LoopScan sc;
    OlState st = {0};
    if (!scan_loop(c, s, &sc)) {
        scan_free(&sc);
        return 0;
    }
    loop_state(c, s, &sc, &st);
    if (st.overflow) {
        scan_free(&sc);
        return 0;
    }
    const char *rt = sc.has_return ? ol_ret_type(c) : NULL;
    int pass_closure = !c->in_main, pass_varargs = b->is_vararg, pass_tbc = b->n_close > 0;
    int id = c->n_outlined++;

    WatBuilder fn;
    wat_init(&fn);
    WatBuilder *outer = c->w;
    c->w = &fn;
    emit_loop_function(c, s, id, &sc, &st, rt, pass_closure, pass_varargs, pass_tbc);
    c->w = outer;
    wat_append(&c->ol_pending, wat_cstr(&fn));
    wat_free(&fn);

    emit_loop_call(c, id, &st, rt, pass_closure, pass_varargs, pass_tbc, sc.has_return, depth);
    scan_free(&sc);
    return 1;
}

/* The header of a loop being emitted into an outlined function: count down
 * the budget, and at the outlined loop's own header suspend once it has run
 * out. */
void ol_loop_header(CG *c, const Stmt *s, int depth) {
    if (!c->ol_active) return;
    emit_line(c, depth, "(local.set $ol_budget (i32.sub (local.get $ol_budget) (i32.const 1)))\n");
    if (s == c->ol_loop)
        emit_line(c, depth, "(br_if $ol_suspend (i32.lt_s (local.get $ol_budget) (i32.const 0)))\n");
}

/* Bracket the outlined loop's own setup (evaluating a for's bounds or
 * iterator): only the first call runs it; a resumed call has its state. */
void ol_init_open(CG *c, const Stmt *s, int depth) {
    if (s == c->ol_loop) emit_line(c, depth, "(if (i32.eqz (local.get $olp_resume)) (then\n");
}
void ol_init_close(CG *c, const Stmt *s, int depth) {
    if (s == c->ol_loop) emit_line(c, depth, "))\n");
}

/* Append the outlined functions of the function just finished. */
void ol_flush(CG *c) {
    if (c->ol_pending.used == 0) return;
    wat_append(c->w, wat_cstr(&c->ol_pending));
    c->ol_pending.used = 0;
    if (c->ol_pending.buf) c->ol_pending.buf[0] = '\0';
}
