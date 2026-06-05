// Test driver for the --embed-api host-call ABI. Given a module compiled from
// tests/fixtures/embed_api.lua with --embed-api, it exercises the exported
// lua_call / lua_get_global / lua_args_* / lua_str_* surface: calling named Lua
// functions with int/float/string args, reading single and multiple results,
// persistent state across calls, and Lua-error propagation.
//
//   node --experimental-wasm-exnref tests/test_embed_api.mjs <module.wasm>

import { readFileSync } from "node:fs";

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error("usage: node test_embed_api.mjs <module.wasm>");
  process.exit(2);
}

const mod = new WebAssembly.Module(readFileSync(wasmPath));
// --embed-api keeps the whole stdlib live, so the module imports the full host
// set. None are called by this fixture; stub them so instantiation succeeds.
const host = {};
for (const imp of WebAssembly.Module.imports(mod)) {
  if (imp.module === "host") host[imp.name] = () => { throw new Error(`host.${imp.name} called unexpectedly`); };
}
const S = new WebAssembly.Instance(mod, { host }).exports;
S.main(); // define globals

const enc = new TextEncoder();
const dec = new TextDecoder();

function luaStr(s) {
  const b = enc.encode(s);
  const v = S.lua_str_new(b.length);
  for (let i = 0; i < b.length; i++) S.lua_str_setb(v, i, b[i]);
  return v;
}
function luaArg(x) {
  if (typeof x === "string") return luaStr(x);
  return Number.isInteger(x) ? S.lua_make_int(BigInt(x)) : S.lua_make_float(x);
}
function call(name, ...args) {
  const fn = S.lua_get_global(luaStr(name));
  const a = S.lua_args_new(args.length);
  args.forEach((x, i) => S.lua_args_set(a, i, luaArg(x)));
  const res = S.lua_call(fn, a);
  const out = [];
  for (let i = 0; i < S.lua_args_len(res); i++) out.push(fromLua(S.lua_args_get(res, i)));
  return out;
}
function fromLua(v) {
  switch (S.lua_tag(v)) {
    case 2: return Number(S.lua_get_int(v));
    case 3: return S.lua_get_float(v);
    case 4: { const n = S.lua_str_len(v); const b = new Uint8Array(n);
              for (let i = 0; i < n; i++) b[i] = S.lua_str_byte(v, i); return dec.decode(b); }
    default: return null;
  }
}

let failures = 0;
function check(label, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { console.error(`FAIL ${label}: got ${g}, want ${w}`); failures++; }
  else console.log(`ok   ${label} = ${g}`);
}

check("add(2,3)", call("add", 2, 3), [5]);
check("add(-4,10)", call("add", -4, 10), [6]);
check("add(1.5,2.25)", call("add", 1.5, 2.25), [3.75]);
check('greet("world")', call("greet", "world"), ["hello, world"]);
check("divmod(17,5)", call("divmod", 17, 5), [3, 2]); // multiple returns
check("tick x3", [call("tick")[0], call("tick")[0], call("tick")[0]], [1, 2, 3]); // persistent state

// Lua error -> host exception (the exported LuaError tag)
let threw = false;
try { call("boom"); } catch (e) {
  threw = e instanceof WebAssembly.Exception && e.is(S.LuaError);
}
check("boom() raises LuaError", threw, true);

console.log(`\nembed-api: ${failures === 0 ? "all checks passed" : failures + " FAILED"}`);
process.exit(failures === 0 ? 0 : 1);
