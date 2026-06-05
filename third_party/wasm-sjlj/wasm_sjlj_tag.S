/* The `__c_longjmp` Wasm EH tag used by LLVM to implement setjmp/longjmp.
 * Vendored from Emscripten's system/lib/compiler-rt/__c_longjmp.S
 * (Copyright the Emscripten Authors; MIT / University of Illinois NCSA).
 * __builtin_wasm_throw(1, ...) in wasm_sjlj.c references this tag. */

#ifdef __wasm_exception_handling__

#ifdef __wasm64__
#define PTR i64
#else
#define PTR i32
#endif

.globl __c_longjmp
.tagtype __c_longjmp PTR
__c_longjmp:

#endif /* __wasm_exception_handling__ */
