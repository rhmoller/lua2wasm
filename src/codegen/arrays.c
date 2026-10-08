/* Integer-key table access, inline: each `t[i]` site with an int-typed (or
 * maybe-typed) key probes the table's array part itself and calls the
 * prelude helper only when the probe misses (a non-table, a key outside
 * 1..#array part, a hole, a slot the fast path doesn't cover).
 *
 * The helpers do the same probe, but a call is only as cheap as V8 makes it:
 * it inlines callees into a function until the function has grown by a
 * budget, and a big function (a game's frame loop, an outlined run-once
 * loop) gets almost none — so its hottest table reads stayed calls, each
 * one returning a four-value cell (docs/perf-backlog.md, item 1).
 *
 * Every path works on locals the body declares for it (emit_ix_locals):
 * $ix_t / $ix_k hold an evaluated table / i64 key, $ix_v a value, $ix_tt the
 * table once tested and $ix_i the 0-based slot. Operands are evaluated onto
 * the stack before any of them is written, so a nested index expression
 * (`a[b[i]]`) has finished with them by then. */
#include "internal.h"

void emit_ix_locals(WatBuilder *w) {
    wat_append(w, "    (local $ix_t anyref) (local $ix_k i64) (local $ix_v anyref)"
                  " (local $ix_tt (ref null $LuaTable)) (local $ix_i i32)\n");
}

/* The key's i64 (a cell's int part; its tag is checked by the probe). */
static const char *ix_key_i(IxKey k) { return k.cell ? k.cell->i : k.i; }

/* Branch to $ixs<n> (the slow path) unless the key is an int, `tv` is a
 * table and the key lies in 1..#array part; leaves the table in $ix_tt and
 * the slot in $ix_i. `tv` and the key are read more than once: they must be
 * local reads. */
static void emit_ix_probe(CG *c, const char *tv, IxKey k, int n, int depth) {
    const char *ki = ix_key_i(k);
    if (k.cell && k.cell->static_tag != TAG_INT)
        emit_linef(c, depth, "(br_if $ixs%d (i32.ne %s (i32.const %d)))\n", n, k.cell->t, TAG_INT);
    emit_linef(c, depth, "(br_if $ixs%d (i32.eqz (ref.test (ref $LuaTable) %s)))\n", n, tv);
    emit_linef(c, depth, "(local.set $ix_tt (ref.cast (ref $LuaTable) %s))\n", tv);
    /* k - 1 < alen, unsigned: also rejects k < 1 */
    emit_linef(c, depth,
               "(br_if $ixs%d (i64.ge_u (i64.sub %s (i64.const 1))"
               " (i64.extend_i32_u (struct.get $LuaTable $alen (local.get $ix_tt)))))\n",
               n, ki);
    emit_linef(c, depth, "(local.set $ix_i (i32.wrap_i64 (i64.sub %s (i64.const 1))))\n", ki);
}

/* The probed slot's value and its unboxed float (valid when the value is
 * the $g_fmark marker). */
#define IX_SLOT  "(array.get $TArr (struct.get $LuaTable $arr (local.get $ix_tt)) (local.get $ix_i))"
#define IX_FSLOT "(array.get $FArr (struct.get $LuaTable $farr (local.get $ix_tt)) (local.get $ix_i))"

/* The tail of a read site's slow path: the generic read of `tv`[key]. */
static void emit_ix_slow_read(CG *c, const char *helper_ik, const char *helper_mk, const char *tv, IxKey k,
                              int line, int depth) {
    if (k.cell)
        emit_linef(c, depth, "(call %s %s %s %s %s %s (i32.const %d))\n", helper_mk, tv, k.cell->t, k.cell->i,
                   k.cell->f, k.cell->b, line);
    else emit_linef(c, depth, "(call %s %s %s (i32.const %d))\n", helper_ik, tv, k.i, line);
}

/* `t[k]` as a Lua value: one folded (block (result anyref) …) that evaluates
 * the table, then (for an int key) the key, emitted by the caller between
 * emit_ix_get_open and emit_ix_get_close. */
int emit_ix_get_open(CG *c, int depth) {
    int n = c->next_label++;
    emit_linef(c, depth, "(block $ixd%d (result anyref)\n", n);
    return n;
}
void emit_ix_get_close(CG *c, int n, const MCell *cell, int line, int depth) {
    IxKey k = {.i = "(local.get $ix_k)", .cell = cell};
    if (!cell) emit_line(c, depth + 1, "local.set $ix_k\n");
    emit_line(c, depth + 1, "local.set $ix_t\n");
    emit_linef(c, depth + 1, "(block $ixs%d\n", n);
    emit_ix_probe(c, "(local.get $ix_t)", k, n, depth + 2);
    emit_linef(c, depth + 2, "(local.set $ix_v %s)\n", IX_SLOT);
    emit_linef(c, depth + 2, "(if (ref.test (ref $FMark) (local.get $ix_v))\n");
    emit_linef(c, depth + 3, "(then (br $ixd%d (struct.new $LuaFloat %s))))\n", n, IX_FSLOT);
    emit_linef(c, depth + 2, "(br_if $ixs%d (ref.is_null (local.get $ix_v)))\n", n);
    emit_linef(c, depth + 2, "(br $ixd%d (local.get $ix_v)))\n", n);
    emit_ix_slow_read(c, "$lua_index_ik_slow", "$lua_index_mk", "(local.get $ix_t)", k, line, depth + 1);
    emit_line(c, depth, ")\n");
}

/* `t[k]` into cell `d`, with the table (then, for an int key, the key) on the
 * stack: an unboxed float slot arrives as tag 2 and a small int as tag 1, both
 * without a call; any other value is classified by $unbox_num. Nothing is
 * written to `d` before the last branch to the slow path, so `d` may be the
 * key's own cell (`i = t[i]`). */
void emit_ix_get_cell(CG *c, const MCell *cell, const MCell *d, int line, int depth) {
    int n = c->next_label++;
    IxKey k = {.i = "(local.get $ix_k)", .cell = cell};
    if (!cell) emit_line(c, depth, "local.set $ix_k\n");
    emit_line(c, depth, "local.set $ix_t\n");
    emit_linef(c, depth, "(block $ixd%d\n", n);
    emit_linef(c, depth + 1, "(block $ixs%d\n", n);
    emit_ix_probe(c, "(local.get $ix_t)", k, n, depth + 2);
    emit_linef(c, depth + 2, "(local.set $ix_v %s)\n", IX_SLOT);
    emit_linef(c, depth + 2, "(if (ref.test (ref $FMark) (local.get $ix_v))\n");
    emit_linef(c, depth + 3, "(then (local.set %s %s) (local.set %s (i32.const %d)) (br $ixd%d)))\n", d->sf,
               IX_FSLOT, d->st, TAG_FLOAT, n);
    emit_linef(c, depth + 2, "(if (ref.test (ref i31) (local.get $ix_v))\n");
    emit_linef(c, depth + 3,
               "(then (local.set %s (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $ix_v)))))"
               " (local.set %s (i32.const %d)) (br $ixd%d)))\n",
               d->si, d->st, TAG_INT, n);
    emit_linef(c, depth + 2, "(br_if $ixs%d (ref.is_null (local.get $ix_v)))\n", n);
    emit_linef(c, depth + 2, "(local.set %s (local.get $ix_v))\n", d->sb);
    emit_linef(c, depth + 2, "(call $unbox_num (local.get $ix_v))\n");
    emit_linef(c, depth + 2, "local.set %s\n", d->sf);
    emit_linef(c, depth + 2, "local.set %s\n", d->si);
    emit_linef(c, depth + 2, "local.set %s\n", d->st);
    emit_linef(c, depth + 2, "(br $ixd%d))\n", n);
    emit_ix_slow_read(c, "$lua_index_ik_cell_slow", "$lua_index_mk_cell", "(local.get $ix_t)", k, line, depth + 1);
    emit_linef(c, depth + 1, "local.set %s\n", d->sb);
    emit_linef(c, depth + 1, "local.set %s\n", d->sf);
    emit_linef(c, depth + 1, "local.set %s\n", d->si);
    emit_linef(c, depth + 1, "local.set %s\n", d->st);
    emit_line(c, depth, ")\n");
}

/* `tb[k] = v`: overwrite a present array slot in place (a present key never
 * reaches __newindex, so the metatable doesn't matter); a nil `v`, an absent
 * slot or a key past the array part goes through the helper. `tb`, the key
 * and `v` must be local reads. */
void emit_ix_set(CG *c, const char *tb, IxKey k, const char *v, int depth) {
    int n = c->next_label++;
    emit_linef(c, depth, "(block $ixd%d\n", n);
    emit_linef(c, depth + 1, "(block $ixs%d\n", n);
    emit_ix_probe(c, tb, k, n, depth + 2);
    emit_linef(c, depth + 2, "(br_if $ixs%d (ref.is_null %s))\n", n, IX_SLOT);
    emit_linef(c, depth + 2, "(br_if $ixs%d (ref.is_null %s))\n", n, v);
    emit_linef(c, depth + 2, "(array.set $TArr (struct.get $LuaTable $arr (local.get $ix_tt)) (local.get $ix_i) %s)\n",
               v);
    emit_linef(c, depth + 2, "(br $ixd%d))\n", n);
    if (k.cell)
        emit_linef(c, depth + 1, "(call $lua_tabset_mk %s %s %s %s %s %s))\n", tb, k.cell->t, k.cell->i, k.cell->f,
                   k.cell->b, v);
    else emit_linef(c, depth + 1, "(call $lua_tabset_ik %s %s %s))\n", tb, k.i, v);
}

/* `tb[k] = f` for an f64 `f` and an int key: a slot that already holds an
 * unboxed float takes the new one in its f64 storage; anything else goes
 * through $lua_tabset_ik_f. */
void emit_ix_set_f(CG *c, const char *tb, const char *ki, const char *f, int depth) {
    int n = c->next_label++;
    emit_linef(c, depth, "(block $ixd%d\n", n);
    emit_linef(c, depth + 1, "(block $ixs%d\n", n);
    emit_ix_probe(c, tb, (IxKey){.i = ki}, n, depth + 2);
    emit_linef(c, depth + 2, "(br_if $ixs%d (i32.eqz (ref.test (ref $FMark) %s)))\n", n, IX_SLOT);
    emit_linef(c, depth + 2,
               "(array.set $FArr (struct.get $LuaTable $farr (local.get $ix_tt)) (local.get $ix_i) %s)\n", f);
    emit_linef(c, depth + 2, "(br $ixd%d))\n", n);
    emit_linef(c, depth + 1, "(call $lua_tabset_ik_f %s %s %s))\n", tb, ki, f);
}
