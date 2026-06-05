// Differential test: the freestanding wasm build of the compiler must produce
// output byte-identical to the native build. The native compiler is the oracle
// (the same C sources, just a different libc + target), so for every e2e
// fixture we compile the source two ways and diff:
//
//   1. WAT text   — native `lua2wasm input.lua -o native.wat`
//                   vs the wasm module's lua2wasm_compile()
//   2. wasm bytes — native `lua2wasm input.lua -o native.wasm` (with DCE)
//                   vs the wasm module's lua2wasm_assemble(wat)
//
// (1) covers codegen incl. the freestanding strtod/%.17g number paths; (2) also
// covers the freestanding wat2wasm assembler + DCE + the assemble entry point.
//
// The native chunk name is the input basename sans .lua, and the wasm entry
// hardcodes "input", so the native input is staged as input.lua to match.
//
// Usage: node diff_native.mjs <nativeBin> <wasmPath> <srcRoot>

import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadCompiler } from "../../runtime/lua2wasm-wasm.mjs";

const [nativeBin, wasmPath, srcRoot] = process.argv.slice(2);
if (!nativeBin || !wasmPath || !srcRoot) {
  console.error("usage: node diff_native.mjs <nativeBin> <wasmPath> <srcRoot>");
  process.exit(2);
}

const compiler = await loadCompiler(readFileSync(wasmPath));
const tmp = mkdtempSync(join(tmpdir(), "l2w-fs-"));
const stageLua = join(tmp, "input.lua"); // basename "input" matches the wasm entry

const manifest = readFileSync(join(srcRoot, "tests/e2e/manifest.tsv"), "utf8");
const rows = manifest
  .split("\n")
  .filter((l) => l && !l.startsWith("#"))
  .map((l) => l.split("\t"));

let pass = 0,
  skip = 0;
const fails = [];

for (const [name, fixture] of rows) {
  const source = readFileSync(join(srcRoot, fixture), "utf8");
  writeFileSync(stageLua, source);

  // Native WAT (oracle). If the native compiler rejects the fixture (an
  // error-path test), skip — error text is matched only semantically.
  let nativeWat;
  try {
    execFileSync(nativeBin, [stageLua, "-o", join(tmp, "n.wat")], { stdio: "pipe" });
    nativeWat = readFileSync(join(tmp, "n.wat"), "utf8");
  } catch {
    skip++;
    continue;
  }

  // Freestanding WAT.
  let fsWat;
  try {
    fsWat = compiler.compile(source);
  } catch (e) {
    fails.push(`${name}: wasm compile() threw but native succeeded: ${e.message}`);
    continue;
  }
  if (fsWat !== nativeWat) {
    const i = firstDiff(nativeWat, fsWat);
    fails.push(`${name}: WAT differs at offset ${i}\n    native: ${snippet(nativeWat, i)}\n    wasm:   ${snippet(fsWat, i)}`);
    continue;
  }

  // Native wasm bytes (with DCE) vs freestanding assemble().
  execFileSync(nativeBin, [stageLua, "-o", join(tmp, "n.wasm")], { stdio: "pipe" });
  const nativeWasm = readFileSync(join(tmp, "n.wasm"));
  let fsWasm;
  try {
    fsWasm = compiler.assemble(fsWat);
  } catch (e) {
    fails.push(`${name}: wasm assemble() threw: ${e.message}`);
    continue;
  }
  if (Buffer.compare(Buffer.from(fsWasm), nativeWasm) !== 0) {
    fails.push(`${name}: assembled wasm differs (native ${nativeWasm.length}B vs wasm ${fsWasm.length}B)`);
    continue;
  }
  pass++;
}

function firstDiff(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return i;
  return n;
}
function snippet(s, i) {
  return JSON.stringify(s.slice(Math.max(0, i - 10), i + 30));
}

console.log(`freestanding diff: ${pass} identical, ${skip} skipped (native rejects), ${fails.length} failed`);
if (fails.length) {
  for (const f of fails.slice(0, 20)) console.error("  FAIL " + f);
  process.exit(1);
}
if (pass === 0) {
  console.error("no fixtures compared — manifest/path problem?");
  process.exit(1);
}
