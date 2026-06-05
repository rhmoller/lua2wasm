// broker.mjs — the JS orchestrator that sits between the C engine and the Lua
// scripts it runs. This is the layer the "engine is wasm" architecture forces:
// a wasm module cannot instantiate another wasm module, so JS is the only thing
// that can take the bytes engine.wasm produces and turn them into a running
// script instance. It is also the only place that can hold a Lua value (a
// WasmGC ref) *and* read the engine's linear memory, so it does the value
// marshaling between the two worlds.
//
// In a browser this same file would run as a <script type=module>; nothing here
// is Node-specific except how the .wasm bytes are loaded by the caller.

const enc = new TextEncoder();

/**
 * Load the C engine (engine.wasm, compiler linked in).
 * @param {BufferSource} wasmBytes
 * @param {(line:string)=>void} log  sink for the engine's env.log lines
 */
export async function loadEngine(wasmBytes, log = (s) => console.log(s)) {
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    env: {
      abort() { throw new Error("engine aborted (OOM/assert)"); },
      log: (ptr, len) => log(new TextDecoder().decode(mem().subarray(ptr, ptr + len))),
    },
  });
  const e = instance.exports;
  const mem = () => new Uint8Array(e.memory.buffer); // re-derive: memory.grow detaches it

  // Stage a Lua source string into the engine's memory and compile+assemble it
  // to a script.wasm. Returns the module bytes (copied out of engine memory).
  function compileScript(source) {
    const src = enc.encode(source);
    const srcPtr = e.malloc(src.length + 1);
    mem().set(src, srcPtr);
    mem()[srcPtr + src.length] = 0;
    const lenPtr = e.malloc(4);
    const bytesPtr = e.engine_build(srcPtr, lenPtr);
    e.free(srcPtr);
    if (bytesPtr === 0) {
      e.free(lenPtr);
      throw new Error("engine_build failed (compile error — see engine log above)");
    }
    const len = new DataView(e.memory.buffer).getInt32(lenPtr, true);
    const out = mem().slice(bytesPtr, bytesPtr + len);
    e.lua2wasm_free(bytesPtr);
    e.free(lenPtr);
    return out;
  }

  return { exports: e, compileScript };
}

/**
 * Instantiate a compiled Lua module. `host` provides the `host.*` imports the
 * script declares; any it declares but you don't supply throws if actually
 * called (so unwired bindings surface loudly rather than silently no-op).
 * Returns the script's exports (main, lua_tag, lua_get_*, lua_make_*, ...).
 */
export function instantiateScript(scriptBytes, host = {}) {
  const mod = new WebAssembly.Module(scriptBytes);
  const imports = {};
  for (const imp of WebAssembly.Module.imports(mod)) {
    if (imp.module !== "host") continue;
    imports[imp.name] =
      host[imp.name] ??
      (() => { throw new Error(`script called unwired host.${imp.name}`); });
  }
  return new WebAssembly.Instance(mod, { host: imports }).exports;
}

// --- value marshaling: Lua GC value <-> JS primitive ----------------------
// These call the script module's own exports, because only the script can
// interpret its GC objects. tags: 0 nil, 1 bool, 2 int, 3 float, 4 string,
// 5 closure, 6 table.
export function luaToNumber(S, v) {
  switch (S.lua_tag(v)) {
    case 2: return Number(S.lua_get_int(v)); // BigInt -> number
    case 3: return S.lua_get_float(v);
    default: return NaN;
  }
}
export function luaToString(S, v) {
  if (S.lua_tag(v) !== 4) return String(luaToNumber(S, v));
  const n = S.lua_str_len(v);
  const bytes = new Uint8Array(n);
  for (let i = 0; i < n; i++) bytes[i] = S.lua_str_byte(v, i);
  return new TextDecoder().decode(bytes);
}
// Build a Lua number to hand back into a script (e.g. as a host.read_num result).
export const luaInt = (S, n) => S.lua_make_int(BigInt(n));
export const luaFloat = (S, x) => S.lua_make_float(x);
