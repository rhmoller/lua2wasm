// Host-side glue for the freestanding wasm build of the compiler
// (build-wasm/lua2wasm.wasm, produced by scripts/build-wasm.sh — plain clang,
// no Emscripten). The module is an ordinary linear-memory wasm with a tiny
// contract:
//
//   imports  env.abort()            — called on OOM / assertion; we throw
//            env.log(ptr, len)      — a diagnostic line (fprintf to stderr)
//   exports  memory
//            malloc(n) / free(p)    — to stage strings into linear memory
//            lua2wasm_compile(srcPtr) -> watPtr            (NUL-terminated)
//            lua2wasm_compile_ex(srcPtr, treeShake) -> watPtr
//            lua2wasm_assemble(watPtr, outLenPtr, errPtr, errCap) -> bytesPtr
//            lua2wasm_dce_dead_names(watPtr) -> namesPtr
//            lua2wasm_free(p)       — frees compiler-returned buffers
//
// All compiler-returned pointers are owned by the caller and must be released
// with lua2wasm_free; staged inputs are released with free. Because the
// allocator grows memory via memory.grow, every access re-derives the view
// from exports.memory.buffer (a grow detaches the old ArrayBuffer).
//
// A C game engine embedding the compiler skips this file entirely: it calls
// the same exports in-process. This glue is for JS hosts (the playground, the
// test harness, Node tooling).

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * Instantiate the compiler module.
 * @param {BufferSource|Response|Promise<Response>} source wasm bytes or a
 *        fetch() Response (or promise of one) for streaming instantiation.
 * @param {(line: string) => void} [onLog] sink for diagnostic lines.
 * @returns {Promise<Lua2Wasm>}
 */
export async function loadCompiler(source, onLog = (line) => console.error(line)) {
  let exports;

  const env = {
    abort() {
      throw new Error("lua2wasm: abort() (out of memory or internal assertion)");
    },
    log(ptr, len) {
      onLog(decoder.decode(view().subarray(ptr, ptr + len)));
    },
  };

  const imports = { env };
  let instance;
  if (typeof Response !== "undefined" && (source instanceof Response || source?.then)) {
    ({ instance } = await WebAssembly.instantiateStreaming(source, imports));
  } else {
    const bytes = source instanceof Uint8Array ? source : new Uint8Array(source);
    ({ instance } = await WebAssembly.instantiate(bytes, imports));
  }
  exports = instance.exports;

  // Fresh memory view (the backing ArrayBuffer changes on memory.grow).
  const view = () => new Uint8Array(exports.memory.buffer);

  function readCString(ptr) {
    if (!ptr) return null;
    const m = view();
    let end = ptr;
    while (m[end] !== 0) end++;
    return decoder.decode(m.subarray(ptr, end));
  }

  // Stage a JS string as a NUL-terminated UTF-8 buffer in linear memory.
  function stageString(s) {
    const bytes = encoder.encode(s);
    const ptr = exports.malloc(bytes.length + 1);
    if (!ptr) throw new Error("lua2wasm: malloc failed");
    const m = view();
    m.set(bytes, ptr);
    m[ptr + bytes.length] = 0;
    return ptr;
  }

  /** @typedef {{compile: Function, assemble: Function, deadNames: Function, exports: object}} Lua2Wasm */
  return {
    /**
     * Compile Lua source to WAT text.
     * @param {string} source
     * @param {{treeShake?: boolean, embedApi?: boolean}} [opts]
     *   embedApi exports the host-call ABI (lua_call/lua_get_global/...) so an
     *   embedder can invoke Lua functions in the produced module; it keeps the
     *   whole stdlib live (no tree-shaking). See examples/embed/.
     * @returns {string} WAT
     * @throws if the compiler reports a lex/parse/codegen error.
     */
    compile(source, { treeShake = false, embedApi = false } = {}) {
      const srcPtr = stageString(source);
      let outPtr;
      try {
        outPtr = exports.lua2wasm_compile_ex(srcPtr, treeShake ? 1 : 0, embedApi ? 1 : 0);
      } finally {
        exports.free(srcPtr);
      }
      const out = readCString(outPtr);
      if (outPtr) exports.lua2wasm_free(outPtr);
      if (out === null) throw new Error("lua2wasm: compile returned null");
      if (out.startsWith("ERROR(")) throw new Error(out);
      return out;
    },

    /**
     * Assemble WAT text into a binary wasm module.
     * @param {string} wat
     * @returns {Uint8Array} a copy of the module bytes (owns no wasm memory).
     * @throws with the assembler's message on failure.
     */
    assemble(wat) {
      const watPtr = stageString(wat);
      const outLenPtr = exports.malloc(4);
      const errCap = 256;
      const errPtr = exports.malloc(errCap);
      let bytesPtr;
      try {
        bytesPtr = exports.lua2wasm_assemble(watPtr, outLenPtr, errPtr, errCap);
        if (!bytesPtr) {
          throw new Error(readCString(errPtr) || "lua2wasm: assemble failed");
        }
        const len = new DataView(exports.memory.buffer).getInt32(outLenPtr, true);
        // Copy out of wasm memory before freeing.
        const out = view().slice(bytesPtr, bytesPtr + len);
        exports.lua2wasm_free(bytesPtr);
        return out;
      } finally {
        exports.free(watPtr);
        exports.free(outLenPtr);
        exports.free(errPtr);
      }
    },

    /**
     * The function/global names DCE would drop from `wat`. Used by the
     * playground to dim dead regions. null if the WAT can't be assembled.
     * @param {string} wat
     * @returns {string[]|null}
     */
    deadNames(wat) {
      const watPtr = stageString(wat);
      let p;
      try {
        p = exports.lua2wasm_dce_dead_names(watPtr);
      } finally {
        exports.free(watPtr);
      }
      if (!p) return null;
      const s = readCString(p);
      exports.lua2wasm_free(p);
      return s ? s.split("\n").filter(Boolean) : [];
    },

    exports,
  };
}
