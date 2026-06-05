// demo.mjs — drives examples/embed/engine.wasm to prove the full embedding
// loop: a C engine (compiler linked in) compiles Lua at runtime, the broker
// instantiates the result, and data flows both directions across the
// linear-memory <-> WasmGC boundary.
//
//   node examples/embed/demo.mjs
//
// (Run examples/embed/build.sh first to produce engine.wasm.)

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { loadEngine, instantiateScript, luaToNumber, luaInt, callLua } from "./broker.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const engine = await loadEngine(readFileSync(join(here, "engine.wasm")));

console.log("=".repeat(70));
console.log("Demo 1 — script -> engine");
console.log("  A Lua script computes numbers; each print() is routed into the C");
console.log("  engine (engine_on_value), which accumulates a running total.");
console.log("=".repeat(70));

{
  const src = `for i = 1, 5 do print(i * i) end`;
  console.log("  lua: " + src);
  const bytes = engine.compileScript(src); // engine compiled this, in its own memory
  let S;
  S = instantiateScript(bytes, {
    // host.print(value) -> reduce the Lua value to a double, hand to the engine
    print: (v) => engine.exports.engine_on_value(luaToNumber(S, v)),
  });
  S.main();
  const total = engine.exports.engine_total();
  console.log(`  => engine_total() = ${total}   (expected 1+4+9+16+25 = 55)`);
}

console.log();
console.log("=".repeat(70));
console.log("Demo 2 — engine -> script -> engine, once per 'frame'");
console.log("  The engine feeds each frame's input number into the script (via the");
console.log("  script's io.read('n') -> host.read_num), the script computes, and the");
console.log("  result flows back out through print(). Fresh script instance per frame");
console.log("  (the script is stateless here — see README for the persistent-state gap).");
console.log("=".repeat(70));

{
  const src = `local dt = io.read("n")\nprint(dt * 3)`;
  console.log("  lua: " + src.replace(/\n/g, "  "));
  const bytes = engine.compileScript(src);
  for (const frame of [10, 20, 30]) {
    let S;
    S = instantiateScript(bytes, {
      // engine -> script: hand the script this frame's number
      read_num: () => luaInt(S, frame),
      // script -> engine: result back out
      print: (v) => engine.exports.engine_on_value(luaToNumber(S, v)),
    });
    console.log(`  frame: engine feeds ${frame}`);
    S.main();
  }
  console.log(`  => engine_total() = ${engine.exports.engine_total()}`);
  console.log("     (55 from demo 1, + 30+60+90 = 235)");
}

console.log();
console.log("=".repeat(70));
console.log("Demo 3 — engine calls NAMED Lua functions, with persistent state");
console.log("  The real scripting model: one long-lived script instance whose");
console.log("  functions the engine invokes by name (lua_call), passing arguments");
console.log("  and reading results. Enabled by compiling with --embed-api (engine.c");
console.log("  passes embed_api=1).");
console.log("=".repeat(70));

{
  const src = [
    `function add(a, b) return a + b end`,
    `hp = 100`,
    `function damage(n) hp = hp - n; return hp end`,
  ].join("\n");
  console.log("  lua: " + src.replace(/\n/g, "  "));
  const bytes = engine.compileScript(src);
  const S = instantiateScript(bytes, {}); // these functions call no host imports
  S.main(); // define add / damage / hp

  console.log("  engine: add(40, 2)   ->", callLua(S, "add", 40, 2)); // [42]
  console.log("  engine: damage(30)   ->", callLua(S, "damage", 30)); // [70]
  console.log("  engine: damage(25)   ->", callLua(S, "damage", 25)); // [45]  (hp persisted!)
}

console.log();
console.log("Data crossed the linear-memory <-> WasmGC boundary in both directions,");
console.log("with the JS broker marshaling via the script's lua_* exports — and the");
console.log("engine drove named Lua functions on a persistent instance via lua_call.");
