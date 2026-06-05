/* Freestanding <setjmp.h> for the wasm32 build.
 *
 * Under `-nostdlib` there is no libc header, so we supply our own. clang's
 * `-mllvm -wasm-enable-sjlj` pass recognizes calls to functions literally
 * named `setjmp`/`longjmp` and lowers them to the four `__wasm_*` support
 * symbols implemented in third_party/wasm-sjlj/. All this header has to do is:
 *   - name `setjmp`/`longjmp` so the pass can find the calls, and
 *   - give `jmp_buf` enough size/alignment to hold `struct jmp_buf_impl`
 *     (func_invocation_id + label + {env,val} = 16 bytes on wasm32).
 * Eight pointers (32 bytes) is generous headroom, pointer-aligned. */
#ifndef _SETJMP_H
#define _SETJMP_H

typedef struct __jmp_buf_tag {
    void *__data[8];
} jmp_buf[1];

int setjmp(jmp_buf env);
_Noreturn void longjmp(jmp_buf env, int val);

#endif /* _SETJMP_H */
