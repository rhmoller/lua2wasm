#!/usr/bin/env node
// Every Lua error the runtime raises must go through $raised, which runs an
// active xpcall's message handler where the error is raised (and turns a nil
// error object into "<no error object>"): `(throw $LuaError (call $raised v))`.
// Only rethrowing an error already raised may throw the value bare, and such a
// site says so with a `;; rethrow` comment on its line. A bare throw anywhere
// else would let that error slip past xpcall handlers unnoticed, so this check
// (CTest test_prelude_raises) fails on one.
//
//   node scripts/check-raises.mjs [repo-root]
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2] ?? ".";
const inDir = (dir, ext) =>
  readdirSync(join(root, dir)).filter((f) => f.endsWith(ext)).map((f) => join(root, dir, f));

let bad = 0;
const report = (file, line, text) => {
  console.error(`${file}:${line}: bare throw of a new error (use $raised, or mark a rethrow): ${text.trim()}`);
  bad++;
};

// The runtime prelude: `;;` starts a comment, and an operand may start on the
// line after the throw.
for (const file of inDir("runtime/prelude", ".wat")) {
  const lines = readFileSync(file, "utf8").split("\n");
  const code = lines.map((l) => l.replace(/;;.*$/, "")).join("\n");
  for (const m of code.matchAll(/\(throw \$LuaError\s+/g)) {
    const at = m.index + m[0].length;
    if (code.startsWith("(call $raised", at)) continue;
    const line = code.slice(0, m.index).split("\n").length;
    if (/;;\s*rethrow\b/.test(lines[line - 1])) continue;
    report(file, line, lines[line - 1]);
  }
}

// WAT the code generator emits: it raises only through prelude helpers, so any
// throw it writes must go through $raised too.
for (const file of inDir("src/codegen", ".c")) {
  const lines = readFileSync(file, "utf8").split("\n");
  lines.forEach((text, i) => {
    for (const m of text.matchAll(/throw \$LuaError\s*/g))
      if (!text.startsWith("(call $raised", m.index + m[0].length)) report(file, i + 1, text);
  });
}

if (bad) process.exit(1);
console.log("check-raises: every raise goes through $raised");
