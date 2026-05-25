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
const oursDce = (wat) => assembleWith(WAT2WASM, ["--dce"], wat);
const reference = (wat) =>
  assembleWith(WASM_AS, ["--all-features", "--disable-custom-descriptors"], wat);

async function instantiate(bytes, imports) {
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  return instance.exports;
}

// Read the leading vector count of a wasm section (e.g. the type section's
// entry count), or 0 if the section is absent.
function sectionCount(bytes, secId) {
  let p = 8;
  const uleb = () => {
    let sh = 0, n = 0, b;
    do { b = bytes[p++]; n |= (b & 0x7f) << sh; sh += 7; } while (b & 0x80);
    return n >>> 0;
  };
  while (p < bytes.length) {
    const id = bytes[p++];
    const len = uleb();
    const end = p + len;
    if (id === secId) return uleb();
    p = end;
  }
  return 0;
}
const typeCount = (b) => sectionCount(b, 1);

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

test("typed select picks a reference value", async () => {
  // Reference-typed operands require the typed form (select (result T) ...).
  // The numeric-specialization codegen emits exactly this to choose a boxed
  // value (e.g. $g_true/$g_false) by an i32 comparison result.
  await check(
    `(module (func (export "pick") (param i32) (result i32)
       (i31.get_s (ref.cast (ref i31)
         (select (result anyref)
           (ref.i31 (i32.const 10))
           (ref.i31 (i32.const 20))
           (local.get 0))))))`,
    (e, who) => {
      assert.equal(e.pick(1), 10, who);
      assert.equal(e.pick(0), 20, who);
    },
  );
});

test("explicit return", async () => {
  await check(
    `(module (func (export "f") (result i32) (return (i32.const 5)) (i32.const 9)))`,
    (e, who) => assert.equal(e.f(), 5, who),
  );
});

// --- increment 2: control flow, globals, calls -------------------------

test("mutable global get/set", async () => {
  await check(
    `(module
       (global $g (mut i32) (i32.const 1))
       (func (export "bump") (result i32)
         (global.set $g (i32.add (global.get $g) (i32.const 10)))
         (global.get $g)))`,
    (e, who) => {
      assert.equal(e.bump(), 11, who);
      assert.equal(e.bump(), 21, who);
    },
  );
});

test("immutable global", async () => {
  await check(
    `(module (global $k i32 (i32.const 7))
       (func (export "f") (result i32) (global.get $k)))`,
    (e, who) => assert.equal(e.f(), 7, who),
  );
});

test("call another function", async () => {
  await check(
    `(module
       (func $sq (param i32) (result i32) (i32.mul (local.get 0) (local.get 0)))
       (func (export "f") (param i32) (result i32)
         (i32.add (call $sq (local.get 0)) (i32.const 1))))`,
    (e, who) => assert.equal(e.f(5), 26, who),
  );
});

test("if/else yielding a value", async () => {
  await check(
    `(module (func (export "max") (param i32 i32) (result i32)
       (if (result i32) (i32.gt_s (local.get 0) (local.get 1))
         (then (local.get 0))
         (else (local.get 1)))))`,
    (e, who) => {
      assert.equal(e.max(3, 8), 8, who);
      assert.equal(e.max(9, 2), 9, who);
    },
  );
});

test("br carries a value out of a block", async () => {
  // unconditional branch with a result value; the trailing const is dead code
  await check(
    `(module (func (export "f") (result i32)
       (block $out (result i32)
         (br $out (i32.const 100))
         (i32.const 7))))`,
    (e, who) => assert.equal(e.f(), 100, who),
  );
});

test("loop countdown sum", async () => {
  // sum 1..n via a loop with br_if back-edge
  await check(
    `(module (func (export "sum") (param $n i32) (result i32)
       (local $acc i32)
       (block $done
         (loop $lp
           (br_if $done (i32.eqz (local.get $n)))
           (local.set $acc (i32.add (local.get $acc) (local.get $n)))
           (local.set $n (i32.sub (local.get $n) (i32.const 1)))
           (br $lp)))
       (local.get $acc)))`,
    (e, who) => {
      assert.equal(e.sum(5), 15, who);
      assert.equal(e.sum(0), 0, who);
    },
  );
});

test("multi-value block type", async () => {
  // a block that leaves two i32s on the stack, consumed by i32.add
  await check(
    `(module (func (export "f") (result i32)
       (i32.add (block (result i32 i32) (i32.const 3) (i32.const 4)))))`,
    (e, who) => assert.equal(e.f(), 7, who),
  );
});

test("return_call (tail call)", async () => {
  await check(
    `(module
       (func $inc (param i32) (result i32) (i32.add (local.get 0) (i32.const 1)))
       (func (export "f") (param i32) (result i32)
         (return_call $inc (local.get 0))))`,
    (e, who) => assert.equal(e.f(41), 42, who),
  );
});

// --- increment 3: WasmGC types and ops ---------------------------------

test("struct.new / struct.get", async () => {
  await check(
    `(module
       (type $pair (struct (field i32) (field i32)))
       (func (export "f") (result i32)
         (struct.get $pair 1 (struct.new $pair (i32.const 10) (i32.const 20)))))`,
    (e, who) => assert.equal(e.f(), 20, who),
  );
});

test("struct.set on a mutable field", async () => {
  await check(
    `(module
       (type $box (struct (field (mut i32))))
       (func (export "f") (result i32)
         (local $b (ref $box))
         (local.set $b (struct.new $box (i32.const 1)))
         (struct.set $box 0 (local.get $b) (i32.const 99))
         (struct.get $box 0 (local.get $b))))`,
    (e, who) => assert.equal(e.f(), 99, who),
  );
});

test("array.new_fixed / array.set / array.get / array.len", async () => {
  await check(
    `(module
       (type $arr (array (mut i32)))
       (func (export "f") (result i32)
         (local $a (ref $arr))
         (local.set $a (array.new_fixed $arr 3 (i32.const 5) (i32.const 6) (i32.const 7)))
         (array.set $arr (local.get $a) (i32.const 1) (i32.const 60))
         (i32.add (array.get $arr (local.get $a) (i32.const 1))
                  (array.len (local.get $a)))))`,
    (e, who) => assert.equal(e.f(), 63, who),
  );
});

test("array.new (fill) and packed i8 array.get_u", async () => {
  await check(
    `(module
       (type $i32a (array (mut i32)))
       (type $bytes (array (mut i8)))
       (func (export "fill") (result i32)
         (array.get $i32a (array.new $i32a (i32.const 9) (i32.const 4)) (i32.const 2)))
       (func (export "byte") (result i32)
         (array.get_u $bytes
           (array.new_fixed $bytes 2 (i32.const 200) (i32.const 1)) (i32.const 0))))`,
    (e, who) => {
      assert.equal(e.fill(), 9, who);
      assert.equal(e.byte(), 200, who);
    },
  );
});

test("array.copy", async () => {
  await check(
    `(module
       (type $arr (array (mut i32)))
       (func (export "f") (result i32)
         (local $a (ref $arr)) (local $b (ref $arr))
         (local.set $a (array.new_fixed $arr 3 (i32.const 1) (i32.const 2) (i32.const 3)))
         (local.set $b (array.new $arr (i32.const 0) (i32.const 3)))
         (array.copy $arr $arr (local.get $b) (i32.const 0) (local.get $a) (i32.const 0)
                     (i32.const 3))
         (array.get $arr (local.get $b) (i32.const 2))))`,
    (e, who) => assert.equal(e.f(), 3, who),
  );
});

test("ref.test / ref.cast through anyref", async () => {
  await check(
    `(module
       (type $box (struct (field i32)))
       (func (export "f") (result i32)
         (local $a anyref)
         (local.set $a (struct.new $box (i32.const 42)))
         (i32.add (ref.test (ref $box) (local.get $a))
                  (struct.get $box 0 (ref.cast (ref $box) (local.get $a))))))`,
    (e, who) => assert.equal(e.f(), 43, who),
  );
});

test("ref.null / ref.is_null", async () => {
  await check(
    `(module
       (type $box (struct (field i32)))
       (func (export "f") (result i32) (ref.is_null (ref.null $box))))`,
    (e, who) => assert.equal(e.f(), 1, who),
  );
});

test("ref.i31 / i31.get_s", async () => {
  await check(
    `(module (func (export "f") (result i32) (i31.get_s (ref.i31 (i32.const -5)))))`,
    (e, who) => assert.equal(e.f(), -5, who),
  );
});

test("ref.eq", async () => {
  await check(
    `(module
       (type $box (struct (field i32)))
       (func (export "f") (result i32)
         (local $a (ref $box))
         (local.set $a (struct.new $box (i32.const 0)))
         (i32.add (ref.eq (local.get $a) (local.get $a))
                  (ref.eq (local.get $a) (struct.new $box (i32.const 0))))))`,
    (e, who) => assert.equal(e.f(), 1, who),
  );
});

test("recursive type (self-referential struct)", async () => {
  await check(
    `(module
       (rec (type $node (struct (field i32) (field (ref null $node)))))
       (func (export "f") (result i32)
         (local $a (ref $node))
         (local.set $a (struct.new $node (i32.const 1) (ref.null $node)))
         (local.set $a (struct.new $node (i32.const 2) (local.get $a)))
         (i32.add (struct.get $node 0 (local.get $a))
                  (struct.get $node 0
                    (ref.cast (ref $node) (struct.get $node 1 (local.get $a)))))))`,
    (e, who) => assert.equal(e.f(), 3, who),
  );
});

test("subtyping with (sub ...)", async () => {
  await check(
    `(module
       (type $base (sub (struct (field i32))))
       (type $derived (sub $base (struct (field i32) (field i32))))
       (func (export "f") (result i32)
         (local $d (ref $derived))
         (local.set $d (struct.new $derived (i32.const 7) (i32.const 8)))
         (struct.get $base 0 (local.get $d))))`,
    (e, who) => assert.equal(e.f(), 7, who),
  );
});

test("GC const-expr in a global init", async () => {
  await check(
    `(module
       (type $box (struct (field i32)))
       (global $g (ref $box) (struct.new $box (i32.const 77)))
       (func (export "f") (result i32) (struct.get $box 0 (global.get $g))))`,
    (e, who) => assert.equal(e.f(), 77, who),
  );
});

// --- increment 4: func refs, exceptions, data, imports -----------------

test("imported function", async () => {
  await check(
    `(module
       (import "env" "add1" (func $add1 (param i32) (result i32)))
       (func (export "f") (param i32) (result i32) (call $add1 (local.get 0))))`,
    (e, who) => assert.equal(e.f(41), 42, who),
    { env: { add1: (x) => x + 1 } },
  );
});

test("call_ref / ref.func / elem declare", async () => {
  await check(
    `(module
       (type $unary (func (param i32) (result i32)))
       (elem declare func $double)
       (func $double (param i32) (result i32) (i32.mul (local.get 0) (i32.const 2)))
       (func (export "f") (param i32) (result i32)
         (call_ref $unary (local.get 0) (ref.func $double))))`,
    (e, who) => assert.equal(e.f(21), 42, who),
  );
});

test("tag + throw + try_table (catch)", async () => {
  await check(
    `(module
       (tag $err (param i32))
       (func (export "f") (param i32) (result i32)
         (block $h (result i32)
           (try_table (result i32) (catch $err $h)
             (if (local.get 0) (then (throw $err (i32.const 99))))
             (i32.const 0)))))`,
    (e, who) => {
      assert.equal(e.f(1), 99, who);
      assert.equal(e.f(0), 0, who);
    },
  );
});

test("try_table (catch_all)", async () => {
  // catch_all carries no values, so its target block must be void; observe
  // the catch through a local that the throwing path never reaches.
  await check(
    `(module
       (tag $err (param i32))
       (func (export "f") (param i32) (result i32)
         (local $r i32)
         (local.set $r (i32.const 5))
         (block $h
           (try_table (catch_all $h)
             (if (local.get 0) (then (throw $err (i32.const 7))))
             (local.set $r (i32.const 1))))
         (local.get $r)))`,
    (e, who) => {
      assert.equal(e.f(1), 5, who); // threw -> caught -> $r stays 5
      assert.equal(e.f(0), 1, who); // no throw -> $r set to 1
    },
  );
});

test("passive data + array.new_data", async () => {
  await check(
    `(module
       (type $bytes (array (mut i8)))
       (data $d "\\01\\02\\03\\04")
       (func (export "f") (result i32)
         (local $a (ref $bytes))
         (local.set $a (array.new_data $bytes $d (i32.const 0) (i32.const 4)))
         (i32.add (array.get_u $bytes (local.get $a) (i32.const 0))
                  (array.get_u $bytes (local.get $a) (i32.const 3)))))`,
    (e, who) => assert.equal(e.f(), 5, who),
  );
});

// --- dead-code elimination (--dce) -------------------------------------

test("dce removes an unreachable function", async () => {
  const wat = `(module
     (func (export "f") (result i32) (i32.const 1))
     (func $dead (result i32) (i32.const 2)))`;
  const plain = ours(wat);
  const dced = oursDce(wat);
  assert.ok(dced.length < plain.length, "dce output should be smaller");
  assert.equal((await instantiate(dced)).f(), 1);
  assert.equal((await instantiate(plain)).f(), 1);
});

test("dce keeps functions reached indirectly via call_ref/ref.func", async () => {
  const wat = `(module
     (type $t (func (result i32)))
     (func $g (result i32) (i32.const 42))
     (func (export "f") (result i32) (call_ref $t (ref.func $g))))`;
  assert.equal((await instantiate(oursDce(wat))).f(), 42);
});

test("dce keeps functions rooted by a global initializer", async () => {
  const wat = `(module
     (type $t (func (result i32)))
     (func $g (result i32) (i32.const 7))
     (global $cl (ref $t) (ref.func $g))
     (func (export "f") (result i32) (call_ref $t (global.get $cl))))`;
  assert.equal((await instantiate(oursDce(wat))).f(), 7);
});

test("dce keeps a transitive callee but drops its unused sibling", async () => {
  const wat = `(module
     (func $helper (result i32) (i32.const 9))
     (func $unused (result i32) (i32.const 8))
     (func (export "f") (result i32) (call $helper)))`;
  const dced = oursDce(wat);
  assert.equal((await instantiate(dced)).f(), 9);
  assert.ok(dced.length < ours(wat).length, "dce should drop $unused");
});

test("dce drops a signature used only by a dead function", async () => {
  // $dead has a signature no surviving entity shares, so the type section
  // must shrink by exactly that one orphaned signature once $dead is pruned.
  const wat = `(module
     (func (export "f") (result i32) (i32.const 1))
     (func $dead (param i64 f64) (result f64)
       (local.get 0) (drop) (local.get 1)))`;
  const plain = ours(wat);
  const dced = oursDce(wat);
  assert.equal(typeCount(dced), typeCount(plain) - 1, "orphaned signature kept");
  assert.equal((await instantiate(dced)).f(), 1);
});

test("dce keeps a signature still shared with a live function", async () => {
  // Both functions share one interned signature; dropping $dead must not drop
  // the signature, and the live function's type index must still resolve.
  const wat = `(module
     (func (export "f") (param i64 f64) (result f64) (local.get 1))
     (func $dead (param i64 f64) (result f64) (local.get 1)))`;
  const dced = oursDce(wat);
  assert.equal((await instantiate(dced)).f(7n, 2.5), 2.5);
});

test("dce keeps a block-type signature inside a live function", async () => {
  // The multi-value block signature is reachable only through live code; it
  // must survive sig-DCE and the block's type index must still be valid.
  const wat = `(module
     (func (export "f") (result i32)
       (i32.const 2) (i32.const 3)
       (block (param i32 i32) (result i32) (i32.add))))`;
  assert.equal((await instantiate(oursDce(wat))).f(), 5);
});
