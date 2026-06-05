/* engine.c — a stand-in "C game engine, compiled to wasm" that embeds the
 * lua2wasm compiler for scripting. Built into examples/embed/engine.wasm by
 * build.sh: the compiler's freestanding object files are linked straight in
 * (same plain-clang toolchain, shared baselib), so the engine can turn Lua
 * source into a runnable wasm module entirely in its own linear memory.
 *
 * What this file demonstrates about embedding:
 *   - The compiler links into a C host with zero glue (engine_build below just
 *     calls the compiler's compile + assemble entry points).
 *   - The engine deals only in primitives (i32/f64/pointers). It cannot touch
 *     a Lua value directly: those are WasmGC objects living in the *script*
 *     module's GC heap, and a linear-memory C function can't even name that
 *     type. So the JS broker reduces Lua values to primitives (via the script
 *     module's lua_get_* exports) before handing them here — see engine_on_value.
 *
 * What it deliberately does NOT do: call a named Lua function with arguments
 * and read its result back. That needs a new exported `lua_call` primitive in
 * the runtime prelude (the prelude already has the internal $lua_call helper),
 * which is a real codegen change — out of scope for a proof of concept. See
 * README.md. */

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>  /* snprintf  (freestanding fmt.c) */
#include <string.h> /* strlen    (freestanding baselib.c) */

/* The embedded compiler (src/wasm_entry.c, linked in). */
extern char *lua2wasm_compile_ex(const char *src, int tree_shake);
extern uint8_t *lua2wasm_assemble(const char *wat, int *out_len, char *err, int errcap);
extern void lua2wasm_free(void *p);

/* The engine's own host import: a line of text to the embedder's console. */
__attribute__((import_module("env"), import_name("log"))) void host_log(const char *p, int n);

#define EXPORT(name) __attribute__((export_name(name), used))

/* --- engine state: ordinary linear memory, no GC in sight ----------------- */
static long long g_total; /* running sum of the numbers scripts have emitted */

/* Compile Lua source (already staged in our linear memory at `src`) into a
 * binary wasm module. Returns the module bytes (NULL on a compile error) and
 * writes the length to *out_len; the broker reads the bytes out of our memory
 * and instantiates them. Free the buffer with lua2wasm_free. */
EXPORT("engine_build")
uint8_t *engine_build(const char *src, int *out_len) {
    char *wat = lua2wasm_compile_ex(src, 0);
    if (!wat) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    /* A lex/parse/codegen failure comes back as an "ERROR(...)" string, not
     * WAT. Surface it to the embedder's console and bail. */
    if (strncmp(wat, "ERROR", 5) == 0) {
        host_log(wat, (int)strlen(wat));
        lua2wasm_free(wat);
        if (out_len) *out_len = 0;
        return NULL;
    }
    char err[256];
    uint8_t *bytes = lua2wasm_assemble(wat, out_len, err, sizeof err);
    lua2wasm_free(wat);
    if (!bytes) host_log(err, (int)strlen(err));
    return bytes;
}

/* script -> engine. Called (through the broker) every time a running script
 * emits a number — its print / io.write is wired to this. We receive a plain
 * double: the broker already pulled the scalar out of the Lua value using the
 * script module's lua_get_* exports, because we (linear memory) can't hold a
 * GC ref. A real engine would drive game state here; we accumulate and log. */
EXPORT("engine_on_value")
void engine_on_value(double x) {
    g_total += (long long)x;
    char buf[80];
    int n = snprintf(buf, sizeof buf, "    [engine] received %g from script (total now %lld)", x,
                     g_total);
    host_log(buf, n);
}

EXPORT("engine_total")
long long engine_total(void) { return g_total; }
