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
 * Starting from the main chunk, a body that runs once makes these run once:
 *  - a function bound to one of its locals (never reassigned, so it has a
 *    binding) that no closure captures (so nothing else, the function itself
 *    included, can reach it), which the body mentions exactly once: as the
 *    callee of a call outside any loop, or as the function pcall / xpcall is
 *    handed there;
 *  - a function literal handed to pcall / xpcall outside any loop;
 *  - in the main chunk, a global function (`function main() ... end`) that it
 *    defines and calls once, outside any loop, and no code mentions again.
 * pcall / xpcall and globals count only in a globally closed program (no
 * _G / _ENV / load / require reaches them by name) that never assigns the
 * pcall / xpcall names. A body with a goto passes nothing on — a backward
 * goto is a loop too. */
typedef struct {
    CG *c;
    int *uses, *calls; /* per local slot: references; calls outside loops */
    int n, loops, has_goto;
    int handoff;             /* pcall / xpcall are the builtins */
    int *gdefs, *gcalls, ng; /* main only: per global, function definitions and calls outside loops */
    const LuaFunc **gfunc;   /* the function a global's definition assigns */
    const LuaFunc **found;   /* function literals handed to pcall / xpcall */
    int n_found, cap_found;
} OnceScan;

/* Is `f` the pcall or xpcall builtin? */
static int is_handoff(const Expr *f) {
    if (f->kind != EXPR_VAR || f->as.var.kind != VAR_BUILTIN) return 0;
    const char *n = builtin_name(f->as.var.idx);
    return strcmp(n, "pcall") == 0 || strcmp(n, "xpcall") == 0;
}

static void once_expr(const Expr *e, void *ctx) {
    OnceScan *o = ctx;
    if (e->kind == EXPR_VAR && e->as.var.kind == VAR_LOCAL && e->as.var.idx >= 0 && e->as.var.idx < o->n)
        o->uses[e->as.var.idx]++;
    if (e->kind == EXPR_CALL && o->loops == 0) {
        const Expr *f = e->as.call.callee;
        if (o->handoff && is_handoff(f) && e->as.call.nargs > 0) f = e->as.call.args[0];
        if (f->kind == EXPR_VAR && f->as.var.kind == VAR_LOCAL && f->as.var.idx >= 0 && f->as.var.idx < o->n)
            o->calls[f->as.var.idx]++;
        if (f->kind == EXPR_VAR && f->as.var.kind == VAR_GLOBAL && o->gcalls && f->as.var.idx < o->ng)
            o->gcalls[f->as.var.idx]++;
        if (f->kind == EXPR_FUNCTION && f != e->as.call.callee) {
            if (o->n_found == o->cap_found)
                o->found = xrealloc(o->found, (size_t)(o->cap_found = o->cap_found ? 2 * o->cap_found : 4) *
                                                  sizeof *o->found);
            o->found[o->n_found++] = f->as.func_expr.func;
        }
    }
    for_each_subexpr(e, once_expr, o);
}
static void once_block(const Block *b, void *ctx);
static void once_stmt(const Stmt *s, OnceScan *o) {
    int loop = stmt_is_loop(s);
    if (s->kind == STMT_GOTO) o->has_goto = 1;
    /* `function g() ... end` for a global g: a definition */
    if (s->kind == STMT_ASSIGN && o->gdefs && o->loops == 0 && s->as.assign.n_targets == 1 &&
        s->as.assign.n_values == 1 && s->as.assign.targets[0].kind == TGT_VAR &&
        s->as.assign.targets[0].as.var.kind == VAR_GLOBAL && s->as.assign.values[0]->kind == EXPR_FUNCTION) {
        int g = s->as.assign.targets[0].as.var.idx;
        if (g >= 0 && g < o->ng) {
            o->gdefs[g]++;
            o->gfunc[g] = s->as.assign.values[0]->as.func_expr.func;
        }
    }
    o->loops += loop; /* a loop's own expressions count as inside it */
    for_each_own_expr(s, once_expr, o);
    for_each_nested_block(s, once_block, o);
    o->loops -= loop;
}
static void once_block(const Block *b, void *ctx) {
    for (size_t i = 0; i < b->count; i++) once_stmt(b->items[i], ctx);
}

/* Program-wide: how often each global is mentioned (read or assigned), and
 * whether the pcall / xpcall names are ever assigned. */
typedef struct {
    int *mentions, ng;
    int handoff_assigned;
} GlobalScan;
static void gscan_expr(const Expr *e, void *ctx) {
    GlobalScan *g = ctx;
    if (e->kind == EXPR_VAR && e->as.var.kind == VAR_GLOBAL && e->as.var.idx >= 0 && e->as.var.idx < g->ng)
        g->mentions[e->as.var.idx]++;
    if (e->kind == EXPR_FUNCTION) {
        /* nested functions are scanned with the program's function list */
    }
    for_each_subexpr(e, gscan_expr, g);
}
static void gscan_stmt(const Stmt *s, void *ctx) {
    GlobalScan *g = ctx;
    if (s->kind == STMT_ASSIGN)
        for (int i = 0; i < s->as.assign.n_targets; i++) {
            const AssignTarget *t = &s->as.assign.targets[i];
            if (t->kind != TGT_VAR) continue;
            if (t->as.var.kind == VAR_GLOBAL && t->as.var.idx >= 0 && t->as.var.idx < g->ng)
                g->mentions[t->as.var.idx]++;
            if (t->as.var.kind == VAR_BUILTIN) {
                const char *n = builtin_name(t->as.var.idx);
                if (strcmp(n, "pcall") == 0 || strcmp(n, "xpcall") == 0) g->handoff_assigned = 1;
            }
        }
    for_each_own_expr(s, gscan_expr, g);
}

/* Mark what run-once body `fi` (-1: the main chunk) makes run once; returns
 * how many functions it newly marked, appending them to `queue`. */
static int once_body(CG *c, int fi, int closed, const GlobalScan *gs, int *queue, int *nq) {
    const ParseResult *pr = c->pr;
    const LuaFunc *fn = fi >= 0 ? pr->funcs.items[fi] : NULL;
    const Block *body = fn ? &fn->body : &pr->main_body;
    int n = fn ? fn->n_locals : pr->main_n_locals;
    const unsigned char *captured = fn ? fn->captured : pr->main_captured;
    const LuaFunc **slot_func = fi >= 0 ? (c->bind_slot ? c->bind_slot[fi] : NULL) : c->main_slot_func;
    int ng = (int)pr->globals.count, main_globals = fi < 0 && closed;
    OnceScan o = {.c = c,
                  .uses = xcalloc((size_t)n + 1, sizeof(int)),
                  .calls = xcalloc((size_t)n + 1, sizeof(int)),
                  .n = n,
                  .handoff = closed && !gs->handoff_assigned,
                  .ng = ng};
    if (main_globals) {
        o.gdefs = xcalloc((size_t)ng + 1, sizeof(int));
        o.gcalls = xcalloc((size_t)ng + 1, sizeof(int));
        o.gfunc = xcalloc((size_t)ng + 1, sizeof *o.gfunc);
    }
    once_block(body, &o);
    int marked = 0;
#define MARK(F)                                 \
    do {                                        \
        const LuaFunc *f_ = (F);                \
        if (f_ && !c->run_once[f_->func_idx]) { \
            c->run_once[f_->func_idx] = 1;      \
            queue[(*nq)++] = f_->func_idx;      \
            marked++;                           \
        }                                       \
    } while (0)
    if (!o.has_goto) {
        for (int s = 0; s < n && slot_func; s++)
            if (slot_func[s] && !(captured && captured[s]) && o.uses[s] == 1 && o.calls[s] == 1) MARK(slot_func[s]);
        for (int i = 0; i < o.n_found; i++) MARK(o.found[i]);
        if (main_globals)
            for (int g = 0; g < ng; g++)
                if (o.gdefs[g] == 1 && o.gcalls[g] == 1 && gs->mentions[g] == 2) MARK(o.gfunc[g]);
    }
#undef MARK
    free(o.uses);
    free(o.calls);
    free(o.gdefs);
    free(o.gcalls);
    free(o.gfunc);
    free(o.found);
    return marked;
}

void compute_run_once(CG *c, const ParseResult *pr, int closed) {
    int nf = (int)pr->funcs.count;
    c->run_once = xcalloc((size_t)nf + 1, 1);
    GlobalScan gs = {.mentions = xcalloc(pr->globals.count + 1, sizeof(int)), .ng = (int)pr->globals.count};
    walk_stmts(&pr->main_body, gscan_stmt, &gs);
    for (int f = 0; f < nf; f++) walk_stmts(&pr->funcs.items[f]->body, gscan_stmt, &gs);
    int *queue = xcalloc((size_t)nf + 1, sizeof(int)), nq = 0;
    once_body(c, -1, closed, &gs, queue, &nq);
    for (int i = 0; i < nq; i++) once_body(c, queue[i], closed, &gs, queue, &nq);
    free(queue);
    free(gs.mentions);
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
    /* the caller's side of a loop outlined inside this one */
    const char *brt = ol_ret_type(c);
    wat_append(w, "    (local $olc_st i32)\n");
    if (brt) wat_appendf(w, "    (local $olc_ret %s)\n", brt);

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
    const Stmt *saved_loop = c->ol_loop;
    int saved_active = c->ol_active, saved_base = c->ol_break_base, saved_resumed = c->ol_resumed;
    c->ol_resumed = c->ol_active; /* outlined from inside another outlined loop */
    c->ol_active = 1;
    c->ol_loop = s;
    c->ol_break_base = c->break_depth;
    emit_stmt(c, s, 4);
    c->ol_active = saved_active;
    c->ol_loop = saved_loop;
    c->ol_break_base = saved_base;
    c->ol_resumed = saved_resumed;
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
                           int pass_varargs, int pass_tbc, int has_return, int start, int depth) {
    emit_linef(c, depth, "(local.set $olc_st (i32.const %d))\n", start);
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
    if (c->ol_active) {
        /* called from an outlined loop: hand the return on to its caller */
        emit_linef(c, depth + 1, "(then %s(local.set $ol_status (i32.const %d)) (br $ol_exit)))\n",
                   rt ? "(local.set $ol_ret (local.get $olc_ret)) " : "", OL_RETURN);
    } else if (!rt) emit_line(c, depth + 1, "(then (return)))\n");
    else if (rt[0] == '(') emit_line(c, depth + 1, "(then (return (ref.as_non_null (local.get $olc_ret)))))\n");
    else emit_line(c, depth + 1, "(then (return (local.get $olc_ret))))\n");
}

/* Outline loop s at `depth`: emit its function (to ol_pending) and the
 * caller's side, starting with `start` (OL_START, or OL_SUSPENDED to resume a
 * loop whose setup already ran here). Returns 0, emitting nothing, when s
 * can't be outlined (a goto leaves it, or its state is too wide). */
static int outline_loop(CG *c, const Stmt *s, int start, int depth) {
    const Body *b = c->cur_body;
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

    emit_loop_call(c, id, &st, rt, pass_closure, pass_varargs, pass_tbc, sc.has_return, start, depth);
    scan_free(&sc);
    return 1;
}

int emit_outlined_loop(CG *c, const Stmt *s, int depth) {
    const Body *b = c->cur_body;
    if (!b || !b->outline || c->ol_active || c->break_depth != 0) return 0;
    return outline_loop(c, s, OL_START, depth);
}

/* Iterations of the outlined loop below which its first iteration is a large
 * share of the run (see ol_nested_candidate). */
#define OL_FEW_ITERATIONS 64

/* Is loop s a numeric for with constant bounds and at most `few` iterations? */
static int few_iterations(const Stmt *s, int64_t few) {
    if (s->kind != STMT_FOR_NUM) return 0;
    const Expr *a = s->as.for_num.start, *b = s->as.for_num.stop, *st = s->as.for_num.step;
    if (a->kind != EXPR_INT || b->kind != EXPR_INT || (st && (st->kind != EXPR_INT || st->as.i_val == 0))) return 0;
    int64_t step = st ? st->as.i_val : 1;
    double trips = ((double)b->as.i_val - (double)a->as.i_val) / (double)step + 1;
    return trips <= (double)few;
}

/* A loop directly inside the outlined loop (not deeper: each such loop is
 * emitted twice) can continue in a function of its own once its setup has
 * run here, when it has a long way to go (src/codegen/stmt.c,
 * emit_for_num_int): an outer loop with few iterations around a long inner
 * one then switches to optimized code within the first of them. Only an
 * outlined numeric for with constant bounds and few iterations splits its
 * inner loops: with many, the first iteration is a small share of the run,
 * and the copy (module size) and the call site (the outer function's
 * inlining budget) cost more than they bring — fannkuch and particles ran 2%
 * slower with every inner loop split. Whether it can is the same question as
 * for the outlined loop itself, asked without emitting anything. */
int ol_nested_candidate(CG *c, const Stmt *s) {
    /* the outlined loop's break label and s's own are pushed */
    if (!c->ol_active || c->ol_resumed || s == c->ol_loop || c->break_depth != c->ol_break_base + 2) return 0;
    if (!few_iterations(c->ol_loop, OL_FEW_ITERATIONS)) return 0;
    LoopScan sc;
    OlState st = {0};
    int ok = scan_loop(c, s, &sc);
    if (ok) {
        loop_state(c, s, &sc, &st);
        ok = !st.overflow;
    }
    scan_free(&sc);
    return ok;
}
int emit_outlined_resume(CG *c, const Stmt *s, int depth) { return outline_loop(c, s, OL_SUSPENDED, depth); }

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
