// Drift detector for runtime/playground.html's PRESETS list.
//
// Several preset entries in the playground correspond to real on-disk
// fixture or sample Lua files. The pages workflow currently inlines a
// copy of those files into the HTML, which means an edit to the fixture
// silently drifts away from the playground. This script asserts that
// the inlined copies still match their source files.
//
// Adding a new (key, file) pair below is cheap: it locks any future
// preset to its source. Presets without a backing fixture are skipped.
//
// Run via `node scripts/check-presets.mjs`. Not wired into ctest yet
// because several existing presets diverge from their sources on
// purpose (different whitespace / comments). Resync those before
// enabling the check in CI.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SCRIPT_DIR, "..");

/** preset key → fixture path (relative to repo root). */
const BINDINGS = {
    iter:       "tests/fixtures/iterator.lua",
    stdin:      "tests/fixtures/io_read.lua",
    s_hello:    "tests/samples/hello.lua",
    s_account:  "tests/samples/account.lua",
    s_bisect:   "tests/samples/bisect.lua",
    s_globals:  "tests/samples/globals.lua",
    tjdevries:  "tests/fixtures/tjdevries.lua",
};

const html = readFileSync(join(ROOT, "runtime/playground.html"), "utf8");

// Find the `const PRESETS = {` block and use the JS runtime to evaluate
// it. This deliberately mirrors how the browser parses the file.
const start = html.indexOf("const PRESETS = {");
if (start < 0) {
    console.error("could not find `const PRESETS = {` in playground.html");
    process.exit(2);
}
// Walk braces to find the matching close.
let depth = 0;
let inStr = null;
let escaped = false;
let end = -1;
for (let i = start; i < html.length; i++) {
    const c = html[i];
    if (inStr) {
        if (escaped) { escaped = false; continue; }
        if (c === "\\") { escaped = true; continue; }
        if (c === inStr) inStr = null;
        continue;
    }
    if (c === "\"" || c === "'" || c === "`") { inStr = c; continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) { end = i + 1; break; } }
}
if (end < 0) {
    console.error("could not find matching `}` for PRESETS");
    process.exit(2);
}

const literal = html.slice(start + "const PRESETS = ".length, end);
let presets;
try {
    presets = (new Function(`return (${literal});`))();
} catch (e) {
    console.error("failed to eval PRESETS literal:", e.message);
    process.exit(2);
}

let failures = 0;
for (const [key, path] of Object.entries(BINDINGS)) {
    if (!(key in presets)) {
        console.error(`PRESETS is missing key '${key}' (expected to mirror ${path})`);
        failures++;
        continue;
    }
    const onDisk = readFileSync(join(ROOT, path), "utf8");
    if (presets[key] !== onDisk) {
        console.error(`drift: PRESETS['${key}'] differs from ${path}`);
        failures++;
    }
}
if (failures) {
    console.error(`\n${failures} preset(s) out of sync — re-paste the file contents or update the binding.`);
    process.exit(1);
}
console.log(`ok: ${Object.keys(BINDINGS).length} preset(s) match their source files`);
