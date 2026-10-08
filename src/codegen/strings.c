/* Constant strings: the literal pool behind the $str_data segment, the
 * constant-string globals ($kstr_*) hoisted out of the code, and the
 * metamethod-name keys the runtime shares with the program. */
#include "internal.h"

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
StrRef strpool_add(StrPool *p, const char *bytes, size_t len) {
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

void strpool_free(StrPool *p) {
    free(p->bytes);
    free(p->idx);
    p->bytes = NULL;
    p->idx = NULL;
}

/* FNV-1a 32-bit — the same function as $str_hash in runtime/prelude/tables.wat
 * (0 is stored as 1 there, so mirror that). A constant's hash is baked into
 * its global so the runtime never has to compute it. */
int32_t kstr_hash(const char *bytes, size_t len) {
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
const char *kstr_expr(CG *c, const char *bytes, size_t len, char *buf, size_t bufsz) {
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

/* `(global <glob> (ref $LuaString) "<s>")` — an immutable module-level global
 * holding a Lua string whose bytes are inlined via array.new_fixed (a constant
 * expression, unlike array.new_data, so it's valid in a global initializer),
 * with its hash precomputed. Declaring a constant string this way instead of
 * assigning it in $stdlib_init lets DCE drop it when no reachable code reads
 * it. */
void emit_global_const_str(CG *c, const char *glob, const char *s, size_t len) {
    wat_appendf(c->w,
                "  (global %s (ref $LuaString)\n"
                "    (struct.new $LuaString (array.new_fixed $LuaArr %zu",
                glob, len);
    for (size_t i = 0; i < len; i++) wat_appendf(c->w, " (i32.const %u)", (unsigned char)s[i]);
    wat_appendf(c->w, ") (i32.const %d)))\n", (int)kstr_hash(s, len));
}

/* Declare every hoisted constant string registered through kstr_name. */
void emit_kstr_globals(CG *c) {
    if (c->kstr_n == 0) return;
    wat_append(c->w, "\n  ;; @@SECTION:kstr@@ hoisted constant strings (bytes + precomputed hash)\n");
    for (size_t i = 0; i < c->kstr_n; i++) {
        char nb[64];
        StrRef r = c->kstr_list[i];
        snprintf(nb, sizeof nb, "$kstr_%zu_%zu", r.offset, r.len);
        emit_global_const_str(c, nb, c->kstrs.bytes + r.offset, r.len);
    }
}

/* Declare the metamethod-name key globals (see MKEYS). */
void emit_mkey_globals(CG *c) {
    for (size_t k = 0; k < N_MKEYS; k++)
        emit_global_const_str(c, MKEYS[k].name, MKEYS[k].key, strlen(MKEYS[k].key));
}
