/* Module assembly: the embedded runtime prelude and its literal slab, the wasm
 * entries of each Lua function and the main chunk, tree-shaking, $stdlib_init
 * (the global table, the libraries, require), the data segment, the embed
 * API, and codegen_module. */
#include "internal.h"

/* Size of the shared $fmt_buf scratch array (bytes). The runtime chunks
 * large reads/formats through it, so three sites must agree on this number:
 * the allocation in codegen_module, the chunk bounds in runtime/prelude/io.wat, and
 * FMT_BUF_CAP in runtime/host-bindings.mjs. */
#define LUA_FMT_BUF_CAP 16384

/* ============================================================
 * Static prelude
 * ============================================================ */

/* The runtime, emitted at the head of every module: the .wat files under
 * runtime/prelude/, one per topic. The types come first and the host imports
 * second (wasm wants imports before definitions); the rest could come in any
 * order. */
static const char PRELUDE[] = {
#embed "prelude/types.wat"
    ,
#embed "prelude/host.wat"
    ,
#embed "prelude/values.wat"
    ,
#embed "prelude/arith.wat"
    ,
#embed "prelude/tostring.wat"
    ,
#embed "prelude/tables.wat"
    ,
#embed "prelude/index.wat"
    ,
#embed "prelude/control.wat"
    ,
#embed "prelude/calls.wat"
    ,
#embed "prelude/errors.wat"
    ,
#embed "prelude/baselib.wat"
    ,
#embed "prelude/io.wat"
    ,
#embed "prelude/debug.wat"
    ,
#embed "prelude/os.wat"
    ,
#embed "prelude/math.wat"
    ,
#embed "prelude/tablib.wat"
    ,
#embed "prelude/utf8.wat"
    ,
#embed "prelude/patterns.wat"
    ,
#embed "prelude/string.wat"
    ,
#embed "prelude/exports.wat"
    ,
    '\0'};

/* The first LITERAL_PREFIX_LEN bytes of $str_data are reserved error
 * messages and field names that the prelude addresses by *absolute* offset
 * (e.g. `$throw_lit (i32.const 430) (i32.const 25)`). The byte map lives in
 * LITERAL_SLAB below; verify_literal_slab() checks that LITERAL_PREFIX and
 * that map agree, so an edit to one without the other fails the build
 * instead of silently corrupting messages or reading past the slab. */
#define LITERAL_PREFIX     "niltruefalse<float>numberstringtablefunctionboolean__index__add__eq\tLua 5.5'for' step is zeroattempt to call a non-function value__callmodule '' not loadedvalue out of rangedata does not fitinvalid UTF-8 codeattempt to perform arithmeticattempt to index a valuetable index is niltable index is NaNtoo largeyearmonthdayhourminsecwdayydayisdsttable overflowout of limitsmissing sizevariable-length formatnot power of 2invalid formatattempt to divide by zeroattempt to perform 'n%0'attempt to compare two values'__tostring' must return a string'__newindex' chain too long; possible loopattempt to close a non-closable valuevalue expectedcannot change a protected metatablestring expectedtable expectedtable or string expectedinvalid replacement valuestring contains zeros<no error object>invalid value in table for 'concat'base out of rangeposition out of boundsinitial position is a continuation bytefield missing in date tablewrong number of argumentsnumber expected, got stack overflownumber has no integer representationinvalid key to 'next'function expectedfield is not an integervariable got a non-closable valueinvalid order function for sortingbad 'for' limit (bad 'for' step (bad 'for' initial value ()"
#define LITERAL_PREFIX_LEN 1208
static_assert(sizeof(LITERAL_PREFIX) - 1 == LITERAL_PREFIX_LEN,
              "LITERAL_PREFIX_LEN must match the byte length of LITERAL_PREFIX");

/* Executable form of the slab map. Each row is the absolute offset baked
 * into the prelude and the bytes that must live there. Offsets are
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

/* The `(i32.const off) (i32.const len)` operands addressing the slab literal
 * `text`, for emitted code that raises it ($throw_lit / $throw_lit_at). */
const char *slab_ref(const char *text) {
    static char buf[48];
    for (size_t i = 0; i < sizeof(LITERAL_SLAB) / sizeof(LITERAL_SLAB[0]); i++)
        if (strcmp(LITERAL_SLAB[i].s, text) == 0) {
            snprintf(buf, sizeof buf, "(i32.const %u) (i32.const %zu)", LITERAL_SLAB[i].off, strlen(text));
            return buf;
        }
    fprintf(stderr, "lua2wasm: internal: \"%s\" is not a slab literal\n", text);
    abort();
}

/* ----- Lua functions and the main chunk ----- */

/* WAT type keyword for an inferred numeric type. */
static const char *num_wat_ty(NumTy t) {
    return t == NT_INT ? "i64" : t == NT_FLOAT ? "f64"
                                               : "anyref";
}

/* Estimated wasm frame bytes of $user_N, stored in every closure over it for
 * the stack-budget guard ($push_call_frame). An upper bound that needs none
 * of the per-function analyses: every slot counted as a maybe quadruple, the
 * temporary bound taken with no typing information (larger), eight bytes a
 * local, plus a fixed allowance for the call machinery's own frames. */
int fn_frame_weight(CG *c, const LuaFunc *fn) {
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

/* Emit one wasm entry (FnEntry) of Lua function `fn`. */
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

    c->in_main = 0;
    c->entry = entry;
    c->cur_ret_ty = ret_ty;
    Body b = function_body(c, fn);
    body_begin(c, &b, param_seed);
    body_declare_locals(c, &b, fast, fn->is_vararg);

    /* Param extraction: from args[i] (normal), the direct $pi param, or the
     * fast entry's $ai register (nil when the call passed fewer). */
    for (int i = 0; i < fn->n_params; i++) {
        char src[64];
        int sn = direct ? snprintf(src, sizeof src, "(local.get $p%d)", i)
                 : fast ? snprintf(src, sizeof src, "(local.get $a%d)", i)
                        : snprintf(src, sizeof src, "(call $args_at (local.get $args) (i32.const %d))", i);
        if (sn < 0 || (size_t)sn >= sizeof src) {
            cg_error(c, "param-extraction expression too long");
            body_end(c, &b);
            return;
        }
        if (fn->captured && fn->captured[i])
            wat_appendf(w, "    (local.set $L%d (struct.new $Box %s))\n", i, src);
        else
            wat_appendf(w, "    (local.set $L%d %s)\n", i, src);
        if (b.ismaybe && b.ismaybe[i])
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
    body_emit(c, &b);
    body_end(c, &b);

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
}

/* Emit `$main`, the top-level chunk: locals (boxed/unboxed per escape
 * analysis), goto dispatch-id locals, the $stdlib_init call, eager boxing
 * of captured slots, then the body. */
static void emit_main_chunk(CG *c) {
    const ParseResult *pr = c->pr;
    wat_append(c->w, "\n  ;; --- main (top-level chunk) ---\n");
    wat_append(c->w, "  (func $main (export \"main\")\n");
    c->in_main = 1;
    c->entry = ENTRY_GENERIC;
    c->cur_ret_ty = NT_ANY;
    Body b = {
        .body = &pr->main_body,
        .n_locals = pr->main_n_locals,
        .captured = pr->main_captured,
        .func_idx = -1,
        .func_slot = c->main_slot_func,
    };
    body_begin(c, &b, NULL);
    body_declare_locals(c, &b, 0, 0);
    if (!c->skip_runtime_init) wat_append(c->w, "    (call $stdlib_init)\n");
    body_emit(c, &b);
    body_end(c, &b);
    wat_append(c->w, "  )\n");
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

/* ----- $stdlib_init: the global table and the libraries ----- */

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

/* package = { loaded = {}, preload = {}, path, cpath, config } in $tab.
 * No builtins live under this table; require() walks it. The path/cpath/
 * config stubs let tests that probe `type(package.path) == "string"` pass. */
static void emit_package_table(CG *c) {
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
    wat_append(c->w, "    (local.set $tab (call $tab_new))\n");
    for (size_t pi = 0; pi < sizeof(PKG_STR) / sizeof(PKG_STR[0]); pi++) {
        size_t klen = strlen(PKG_STR[pi].key);
        if (PKG_STR[pi].val == NULL)
            emit_tab_set_str(c, "(local.get $tab)", PKG_STR[pi].key, klen,
                             "(call $tab_new)");
        else
            emit_tab_set_strval(c, "(local.get $tab)", PKG_STR[pi].key, klen,
                                PKG_STR[pi].val, strlen(PKG_STR[pi].val));
    }
}

/* io.stdout / io.stderr / io.stdin in the io table ($tab): a sub-table per
 * stream, populated with the relevant file-handle methods. The methods
 * themselves were registered as leading-underscore entries in builtins.c so
 * the library install loop skips them, but their closure globals
 * ($g_io_handle_{write,err_write,read,noop}) are live and ready to use. */
static void emit_std_handles(CG *c) {
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
        wat_append(c->w, "    (local.set $h (call $tab_new))\n");
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
            wat_appendf(c->w, "    (global.set %s (local.get $h))\n",
                        HANDLES[hi].default_global);
    }
}

/* A function-bearing library (math/string/io/table/utf8/debug/os) in $tab:
 * its builtins, then its plain-value fields. */
static void emit_builtin_library(CG *c, BuiltinClass cls, int nb) {
    wat_append(c->w, "    (local.set $tab (call $tab_new))\n");
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
    if (cls == BLT_LIB_IO) emit_std_handles(c);
    if (cls == BLT_LIB_UTF8) {
        /* utf8.charpattern: the Lua-pattern string that matches one
         * UTF-8 codepoint. Binary content; strpool_add and data-segment
         * escaping handle the non-printable bytes. */
        static const char CHARPAT[] =
            "[\x00-\x7F\xC2-\xFD][\x80-\xBF]*";
        emit_tab_set_strval(c, "(local.get $tab)", "charpattern", 11,
                            CHARPAT, sizeof(CHARPAT) - 1);
    }
}

/* Build each referenced stdlib library table (math/string/io/table/utf8/
 * debug/os/package/coroutine) plus _VERSION, and install them in $g_globals.
 * Tree-shake skips a library whose global name was never referenced. */
static void emit_library_tables(CG *c, const unsigned char *gref, int nb) {
    const ParseResult *pr = c->pr;
    const char *G = "(ref.as_non_null (global.get $g_globals))";
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
            emit_package_table(c);
        } else if (glen == 9 && memcmp(gname, "coroutine", 9) == 0) {
            /* Empty stub library — no functions installed. Enough to
             * satisfy `require "coroutine" == coroutine` style identity
             * checks and to keep `type(coroutine) == "table"` happy;
             * any actual coroutine.* call still trips later. */
            wat_append(c->w, "    (local.set $tab (call $tab_new))\n");
        } else {
            /* The function-bearing libraries map name -> BuiltinClass via
             * the same helper the live-set pass uses. */
            int cls = class_for_global(gname, glen);
            if (cls < 0) continue;
            emit_builtin_library(c, (BuiltinClass)cls, nb);
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

/* ----- the module tail ----- */

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
                 "the prelude's offset map disagree",
                 slab_err);
        return 0;
    }

    CG c = {.w = out, .pr = pr, .ok = 1};
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
    unsigned char *live = xcalloc((size_t)nb, 1);
    unsigned char *gref = xcalloc(pr->globals.count + 1, 1);
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

    emit_mkey_globals(&c);
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

    if (!c.ok) snprintf(err, errlen, "%s", c.err);
    strpool_free(&c.strs);
    strpool_free(&c.kstrs);
    free(c.kstr_list);
    free(live);
    free(gref);
    free_func_bindings(&c);
    free_signatures(&c);
    return c.ok;
}
