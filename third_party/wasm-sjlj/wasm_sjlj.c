/* Wasm-EH setjmp/longjmp support runtime.
 *
 * Vendored and trimmed from Emscripten's
 *   system/lib/compiler-rt/emscripten_setjmp.c
 * (Copyright the Emscripten Authors; MIT / University of Illinois NCSA).
 *
 * clang's `-mllvm -wasm-enable-sjlj` lowering rewrites every setjmp/longjmp
 * call into references to these four symbols (the fourth, the `__c_longjmp`
 * exception tag, is declared in wasm_sjlj_tag.S). LLVM hard-codes tag index
 * 1 for `__c_longjmp`, which `__builtin_wasm_throw` emits below. We only ship
 * the native-Wasm-EH path (no Emscripten JS longjmp fallback). */

#include <stdint.h>

struct __WasmLongjmpArgs {
    void *env;
    int val;
};

/* jmp_buf is laid out as this struct; see include/setjmp.h for sizing. */
struct jmp_buf_impl {
    void *func_invocation_id;
    uint32_t label;
    struct __WasmLongjmpArgs arg;
};

void __wasm_setjmp(void *env, uint32_t label, void *func_invocation_id) {
    struct jmp_buf_impl *jb = env;
    jb->func_invocation_id = func_invocation_id;
    jb->label = label;
}

uint32_t __wasm_setjmp_test(void *env, void *func_invocation_id) {
    struct jmp_buf_impl *jb = env;
    if (jb->func_invocation_id == func_invocation_id) {
        return jb->label;
    }
    return 0;
}

/* LLVM uses tag index 1 for the __c_longjmp Wasm EH tag. */
#define C_LONGJMP 1

_Noreturn void __wasm_longjmp(void *env, int val) {
    struct jmp_buf_impl *jb = env;
    struct __WasmLongjmpArgs *arg = &jb->arg;
    /* C: longjmp cannot make setjmp return 0; remap 0 -> 1. */
    if (val == 0) {
        val = 1;
    }
    arg->env = env;
    arg->val = val;
    __builtin_wasm_throw(C_LONGJMP, arg);
}
