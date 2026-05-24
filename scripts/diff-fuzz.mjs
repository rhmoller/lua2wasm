#!/usr/bin/env node
// Generative differential fuzzer for lua2wasm.
//
// Emits random Lua in the *supported subset*, runs each program through both
// lua2wasm -> node host and reference lua5.5, and flags any divergence. A seed
// reproduces a program; a divergence is shrunk to a minimal case you can check
// into tests/diff. See CLAUDE.md "Property-based & differential testing".
//
// This is a discovery tool: it needs `lua5.5` live (like diff-test.sh --regen)
// and is NOT part of the default ctest. Its findings (shrunk tests/diff cases)
// are the durable regression net.
//
// Usage:
//   node scripts/diff-fuzz.mjs                  # 1000 programs, random base seed
//   node scripts/diff-fuzz.mjs --count 5000
//   node scripts/diff-fuzz.mjs --seed 12345     # reproduce one program (prints it, runs it)
//   node scripts/diff-fuzz.mjs --phase numeric  # numeric|format|all (default all)
//   node scripts/diff-fuzz.mjs --emit NAME      # on first divergence, write a tests/diff case
//   LUA_REF=lua5.4 node scripts/diff-fuzz.mjs   # override the reference interpreter

import { execFileSync } from "node:child_process";
import { writeFileSync, mkdtempSync, appendFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SCRIPT_DIR, "..");
const L2W = join(ROOT, "build/lua2wasm");
const HOST = join(ROOT, "runtime/host.mjs");
const LUA = process.env.LUA_REF || "lua5.5";
const WORK = mkdtempSync(join(tmpdir(), "lua2wasm-fuzz-"));
const TIMEOUT_MS = 10000;

// ---- args ----------------------------------------------------------------
const args = process.argv.slice(2);
function flag(name, def) {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : def;
}
const COUNT = parseInt(flag("--count", "1000"), 10);
const ONE_SEED = args.includes("--seed") ? parseInt(flag("--seed"), 10) >>> 0 : null;
const PHASE = flag("--phase", "all"); // numeric | format | all
const EMIT = flag("--emit", null);
const BASE = ONE_SEED ?? (Math.random() * 0x100000000) >>> 0;

// ---- seeded PRNG (mulberry32) -------------------------------------------
function mulberry32(seed) {
    let a = seed >>> 0;
    const r = () => {
        a |= 0;
        a = (a + 0x6d2b79f5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    r.int = (n) => Math.floor(r() * n); // [0, n)
    r.pick = (arr) => arr[r.int(arr.length)];
    r.chance = (p) => r() < p;
    return r;
}

// ---- generator (AST -> Lua text) ----------------------------------------
// Interesting literal values, kept as exact lexical forms so we also exercise
// number *parsing* (e.g. decimal overflow promoting to float).
const INT_LITS = [
    "0", "1", "-1", "2", "3", "7", "-8", "10", "255", "256", "1000000",
    "9223372036854775807", "-9223372036854775807", "9223372036854775808",
    "0x7fffffffffffffff", "0xffffffffffffffff", "0x10",
    "math.maxinteger", "math.mininteger",
];
const FLOAT_LITS = [
    "0.0", "-0.0", "1.0", "1.5", "-2.5", "0.1", "0.5", "3.14", "2.0", "100.0",
    "1e10", "1e308", "1e-308", "1e16", "9007199254740993.0",
    "math.huge", "-math.huge", "math.pi", "(0/0)",
];
// Excludes transcendentals (sin/cos/exp/log/pow-fractional): C libm and our
// runtime aren't guaranteed bit-identical, which would be unfixable noise.
// sqrt/floor/ceil/abs/fmod are IEEE-exact and portable.
const NUM_UNOPS = ["-", "~", "math.floor", "math.ceil", "math.abs",
    "math.sqrt", "math.type", "math.tointeger", "tostring", "tonumber"];
// `^` omitted: pow with a fractional exponent isn't bit-portable across libm.
const NUM_BINOPS = ["+", "-", "*", "/", "//", "%",
    "&", "|", "~", "<<", ">>", "==", "~=", "<", "<=", ">", ">="];

const STR_LITS = [
    '""', '"a"', '"abc"', '"Hello, World"', '"  "', '"\\0"', '"\\255\\1\\0"',
    '"line1\\nline2"', '"123"', '"-45.6"', '"0x1F"', '"  12  "', '"%d"', '"tab\\there"',
];
const FMT_SPECS = [
    '"%d"', '"%i"', '"%5d"', '"%-5d"', '"%05d"', '"%+d"', '"% d"',
    '"%x"', '"%X"', '"%#x"', '"%o"', '"%u"',
    '"%f"', '"%.2f"', '"%10.3f"', '"%-10.3f"', '"%+.1f"', '"%#.0f"',
    '"%e"', '"%E"', '"%.3e"', '"%g"', '"%G"', '"%.10g"',
    '"%s"', '"%10s"', '"%-10s"', '"%.3s"', '"%q"', '"%c"', '"%%x=%d"',
];
const STR_UNOPS = ["string.upper", "string.lower", "string.reverse", "string.len",
    "#", "tostring", "tonumber"];

function lit(rng) {
    return rng.chance(0.5) ? rng.pick(INT_LITS) : rng.pick(FLOAT_LITS);
}

// A numeric expression node. Returns a Lua source string.
function genNum(rng, depth) {
    if (depth <= 0 || rng.chance(0.45)) return lit(rng);
    const kind = rng.int(3);
    if (kind === 0) {
        const op = rng.pick(NUM_UNOPS);
        const a = genNum(rng, depth - 1);
        return /^[~-]$/.test(op) ? `(${op}(${a}))` : `${op}(${a})`;
    }
    if (kind === 1) {
        const op = rng.pick(NUM_BINOPS);
        return `(${genNum(rng, depth - 1)} ${op} ${genNum(rng, depth - 1)})`;
    }
    // math.min/max with two args
    const fn = rng.pick(["math.min", "math.max", "math.fmod"]);
    return `${fn}(${genNum(rng, depth - 1)}, ${genNum(rng, depth - 1)})`;
}

// A string/format expression node.
function genStr(rng, depth) {
    if (depth <= 0 || rng.chance(0.4)) return rng.pick(STR_LITS);
    const kind = rng.int(4);
    if (kind === 0) return `(${genStr(rng, depth - 1)} .. ${genStr(rng, depth - 1)})`;
    if (kind === 1) {
        const op = rng.pick(STR_UNOPS);
        return op === "#" ? `(#${genStr(rng, depth - 1)})` : `${op}(${genStr(rng, depth - 1)})`;
    }
    if (kind === 2) {
        // string.format(spec, arg) — arg is numeric or string per a coin flip.
        const spec = rng.pick(FMT_SPECS);
        const arg = rng.chance(0.6) ? genNum(rng, depth - 1) : genStr(rng, depth - 1);
        return `string.format(${spec}, ${arg})`;
    }
    // string.sub / rep / byte / char with small int args
    const fn = rng.pick(["string.sub", "string.rep", "string.byte"]);
    const n = rng.pick(["0", "1", "2", "3", "-1", "-2", "10"]);
    if (fn === "string.rep") return `string.rep(${genStr(rng, depth - 1)}, ${rng.pick(["0", "1", "2", "3"])})`;
    return `${fn}(${genStr(rng, depth - 1)}, ${n})`;
}

function genExpr(rng) {
    const depth = 2 + rng.int(3);
    const useStr = PHASE === "format" || (PHASE === "all" && rng.chance(0.5));
    return useStr ? genStr(rng, depth) : genNum(rng, depth);
}

// Wrap an expression so output is fully engine-agnostic: success prints the
// value, any error prints just `false <type>` (no chunk-name / interpreter
// prefix to normalize). Explicit `if ok` so a legit false/nil result is exact.
function wrap(exprSrc) {
    return `local ok, v = pcall(function() return ${exprSrc} end)\n`
        + `if ok then print(true, v) else print(false, type(v)) end\n`;
}

// ---- runners -------------------------------------------------------------
// The sign of NaN is IEEE-unspecified and differs by platform/libm (glibc
// prints -nan); already a captured xfail. Canonicalize so it isn't noise.
const norm = (s) => s.replace(/\n$/, "").replace(/-nan/g, "nan");

function runOurs(luaPath) {
    const wasm = join(WORK, "p.wasm");
    try {
        execFileSync(L2W, [luaPath, "-o", wasm], { stdio: ["ignore", "ignore", "pipe"], timeout: TIMEOUT_MS });
    } catch (e) {
        return { cls: "compile-fail", out: (e.stderr || "").toString().trim() };
    }
    try {
        const out = execFileSync("node", ["--experimental-wasm-exnref", HOST, wasm],
            { encoding: "utf8", timeout: TIMEOUT_MS, stdio: ["ignore", "pipe", "pipe"] });
        return { cls: "ok", out: norm(out) };
    } catch (e) {
        if (e.signal || e.code === "ETIMEDOUT") return { cls: "timeout", out: "" };
        return { cls: "error", out: ((e.stdout || "") + "").replace(/\n$/, "") };
    }
}

function runRef(luaPath) {
    try {
        const out = execFileSync(LUA, [luaPath],
            { encoding: "utf8", timeout: TIMEOUT_MS, stdio: ["ignore", "pipe", "pipe"] });
        return { cls: "ok", out: norm(out) };
    } catch (e) {
        if (e.signal || e.code === "ETIMEDOUT") return { cls: "timeout", out: "" };
        if (e.code === "ENOENT") { console.error(`reference '${LUA}' not found (set LUA_REF)`); process.exit(2); }
        return { cls: "error", out: ((e.stdout || "") + "").replace(/\n$/, "") };
    }
}

// Returns null if the two runs agree, else a short reason string.
function diff(ours, ref) {
    if (ours.cls === "ok" && ref.cls === "ok") {
        return ours.out === ref.out ? null : "value mismatch";
    }
    // Both failed to run at all -> generator likely emitted invalid Lua; agree.
    if (ours.cls !== "ok" && ref.cls !== "ok") return null;
    // One ran, the other didn't: a real divergence (we crash/reject valid Lua,
    // or accept what reference rejects). compile-fail / uncatchable trap land here.
    return `${ours.cls} vs ${ref.cls}`;
}

function runBoth(src) {
    const p = join(WORK, "p.lua");
    writeFileSync(p, src);
    const ours = runOurs(p);
    const ref = runRef(p);
    return { ours, ref, reason: diff(ours, ref) };
}

// ---- shrinker ------------------------------------------------------------
// Textual delta-debug: repeatedly try replacing each parenthesized subexpression
// with a simple literal, keeping any change that preserves the divergence.
function shrink(exprSrc) {
    const simples = ["1", "0", "1.5", '"a"', '""'];
    let best = exprSrc;
    let changed = true;
    while (changed) {
        changed = false;
        // find balanced (...) groups and try collapsing each to a literal
        for (let i = 0; i < best.length; i++) {
            if (best[i] !== "(") continue;
            // Only collapse a genuine parenthesized subexpression, not a call's
            // argument list (`f(...)` would shrink to the bogus `f1`).
            if (i > 0 && /[\w.]/.test(best[i - 1])) continue;
            let depth = 0, j = i;
            for (; j < best.length; j++) {
                if (best[j] === "(") depth++;
                else if (best[j] === ")") { depth--; if (depth === 0) break; }
            }
            if (j >= best.length) continue;
            const inner = best.slice(i, j + 1);
            if (/^\(\s*-?[\d.]+\s*\)$/.test(inner)) continue; // already trivial
            for (const s of simples) {
                const cand = best.slice(0, i) + s + best.slice(j + 1);
                if (cand === best) continue;
                if (runBoth(wrap(cand)).reason) { best = cand; changed = true; break; }
            }
            if (changed) break;
        }
    }
    return best;
}

// ---- corpus emit ---------------------------------------------------------
function emitCase(name, src) {
    const caseFile = join(ROOT, "tests/diff/cases", `${name}.lua`);
    const expFile = join(ROOT, "tests/diff/expected", `${name}.expected`);
    const manifest = join(ROOT, "tests/diff/manifest.tsv");
    writeFileSync(caseFile, src.endsWith("\n") ? src : src + "\n");
    const ref = runRef(caseFile); // golden from reference
    writeFileSync(expFile, ref.out);
    appendFileSync(manifest, `xfail\t${name}\tfuzzer-found divergence (shrunk)\n`);
    console.log(`\nwrote tests/diff case '${name}' (xfail). Capture intent, then fix and promote to pass.`);
}

// ---- driver --------------------------------------------------------------
function report(seed, src, r) {
    console.log(`\n=== DIVERGENCE  seed=${seed}  (${r.reason}) ===`);
    console.log(src.trimEnd());
    console.log(`-- ours (${r.ours.cls}): ${JSON.stringify(r.ours.out)}`);
    console.log(`-- ref  (${r.ref.cls}): ${JSON.stringify(r.ref.out)}`);
}

if (!existsSync(L2W)) { console.error(`compiler not built at ${L2W}`); process.exit(2); }

if (ONE_SEED !== null) {
    const rng = mulberry32(ONE_SEED);
    const expr = genExpr(rng);
    const src = wrap(expr);
    console.log(`seed=${ONE_SEED}\n${src}`);
    const r = runBoth(src);
    if (r.reason) report(ONE_SEED, src, r);
    else console.log(`agree: ours=${JSON.stringify(r.ours.out)} ref=${JSON.stringify(r.ref.out)}`);
    process.exit(r.reason ? 1 : 0);
}

console.log(`fuzzing ${COUNT} programs, phase=${PHASE}, base seed=${BASE}, ref=${LUA}`);
let found = 0, bothFail = 0;
for (let i = 0; i < COUNT; i++) {
    const seed = (BASE + i) >>> 0;
    const rng = mulberry32(seed);
    const expr = genExpr(rng);
    const r = runBoth(wrap(expr));
    if (r.ours.cls !== "ok" && r.ref.cls !== "ok") bothFail++;
    if (!r.reason) continue;
    found++;
    report(seed, wrap(expr), r);
    const minimal = shrink(expr);
    if (minimal !== expr) {
        console.log(`-- shrunk: ${minimal}`);
        const mr = runBoth(wrap(minimal));
        console.log(`   ours=${JSON.stringify(mr.ours.out)} ref=${JSON.stringify(mr.ref.out)}`);
    }
    if (EMIT) { emitCase(EMIT, wrap(minimal)); break; }
    if (found >= 25) { console.log("\n(stopping after 25 divergences)"); break; }
}
console.log(`\ndone: ${found} divergence(s) in ${COUNT} programs (${bothFail} both-rejected).`);
process.exit(found ? 1 : 0);
