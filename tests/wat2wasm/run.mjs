// TDD harness for the wat2wasm assembler.
//
// For each case we assemble a small WAT module with our `wat2wasm` binary,
// instantiate it under Node, and assert the behavior of its exports. When
// `wasm-as` is available (WASM_AS env var) we also assemble the same source
// with it and run the identical assertions, so every case doubles as a
// differential check against a reference assembler.
//
// Env:
//   WAT2WASM  path to the built wat2wasm binary (required)
//   WASM_AS   path to Binaryen's wasm-as (optional differential oracle)

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const WAT2WASM = process.env.WAT2WASM;
const WASM_AS = process.env.WASM_AS;
if (!WAT2WASM) throw new Error("WAT2WASM env var (path to wat2wasm binary) is required");

const dir = mkdtempSync(join(tmpdir(), "wat2wasm-"));
let seq = 0;

function assembleWith(bin, args, wat) {
  const watPath = join(dir, `m${seq}.wat`);
  const wasmPath = join(dir, `m${seq}.wasm`);
  seq++;
  writeFileSync(watPath, wat);
  execFileSync(bin, [...args, "-o", wasmPath, watPath]);
  return new Uint8Array(readFileSync(wasmPath));
}

const ours = (wat) => assembleWith(WAT2WASM, [], wat);
const reference = (wat) =>
  assembleWith(WASM_AS, ["--all-features", "--disable-custom-descriptors"], wat);

async function instantiate(bytes, imports) {
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  return instance.exports;
}

// Assemble `wat` with our assembler (and wasm-as if present), instantiate
// each, and run `run(exports, label)` against both.
async function check(wat, run, imports = {}) {
  await run(await instantiate(ours(wat), imports), "wat2wasm");
  if (WASM_AS) await run(await instantiate(reference(wat), imports), "wasm-as");
}

test("empty module validates", () => {
  assert.ok(WebAssembly.validate(ours("(module)")));
});

test("function returns an i32 constant", async () => {
  await check(`(module (func (export "f") (result i32) (i32.const 42)))`, (e, who) =>
    assert.equal(e.f(), 42, who),
  );
});

test("adds two i32 params", async () => {
  await check(
    `(module (func (export "add") (param i32 i32) (result i32)
       (i32.add (local.get 0) (local.get 1))))`,
    (e, who) => assert.equal(e.add(2, 3), 5, who),
  );
});

test("named params and a local", async () => {
  await check(
    `(module (func (export "f") (param $a i32) (result i32)
       (local $t i32)
       (local.set $t (i32.mul (local.get $a) (i32.const 3)))
       (local.get $t)))`,
    (e, who) => assert.equal(e.f(7), 21, who),
  );
});

test("i64 arithmetic", async () => {
  await check(
    `(module (func (export "f") (param i64 i64) (result i64)
       (i64.sub (local.get 0) (local.get 1))))`,
    (e, who) => assert.equal(e.f(10n, 4n), 6n, who),
  );
});

test("f64 arithmetic and comparison", async () => {
  await check(
    `(module
       (func (export "div") (param f64 f64) (result f64)
         (f64.div (local.get 0) (local.get 1)))
       (func (export "lt") (param f64 f64) (result i32)
         (f64.lt (local.get 0) (local.get 1))))`,
    (e, who) => {
      assert.equal(e.div(9, 2), 4.5, who);
      assert.equal(e.lt(1, 2), 1, who);
      assert.equal(e.lt(2, 1), 0, who);
    },
  );
});

test("integer conversions", async () => {
  await check(
    `(module
       (func (export "wrap") (param i64) (result i32) (i32.wrap_i64 (local.get 0)))
       (func (export "ext") (param i32) (result i64) (i64.extend_i32_s (local.get 0))))`,
    (e, who) => {
      assert.equal(e.wrap(0x1_0000_0007n), 7, who);
      assert.equal(e.ext(-1), -1n, who);
    },
  );
});

test("select and drop", async () => {
  await check(
    `(module (func (export "pick") (param i32 i32 i32) (result i32)
       (select (local.get 0) (local.get 1) (local.get 2))))`,
    (e, who) => {
      assert.equal(e.pick(10, 20, 1), 10, who);
      assert.equal(e.pick(10, 20, 0), 20, who);
    },
  );
});

test("explicit return", async () => {
  await check(
    `(module (func (export "f") (result i32) (return (i32.const 5)) (i32.const 9)))`,
    (e, who) => assert.equal(e.f(), 5, who),
  );
});
