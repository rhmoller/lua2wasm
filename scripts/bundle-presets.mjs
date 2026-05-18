#!/usr/bin/env node
// Bundle playground presets into runtime/playground.html.
//
// Source of truth: runtime/presets/manifest.json + the .lua files it
// references. This script regenerates the `const PRESETS = { ... };`
// block in playground.html from those files. Two modes:
//
//   --write   (default): rewrite playground.html in place
//   --check            : exit non-zero if --write would change the file
//                        (CI uses this to catch drift)
//
// Why not a runtime fetch of presets.json? The playground deploys as a
// flat dist/ via GitHub Pages, but local dev opens runtime/playground.html
// directly with the file:// protocol, where fetch() is blocked. Inlining
// dodges that.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SCRIPT_DIR, "..");

const args = process.argv.slice(2);
const mode = args.includes("--check") ? "check" : "write";

const manifestPath = join(ROOT, "runtime/presets/manifest.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

const playgroundPath = join(ROOT, "runtime/playground.html");
const html = readFileSync(playgroundPath, "utf8");

const START_MARKER = "const PRESETS = {";
const start = html.indexOf(START_MARKER);
if (start < 0) {
    console.error(`could not find '${START_MARKER}' in ${playgroundPath}`);
    process.exit(2);
}
// Walk braces, respecting string literals, to find the matching close.
let depth = 0;
let inStr = null;
let escaped = false;
let end = -1;
for (let i = start + START_MARKER.length - 1; i < html.length; i++) {
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
    console.error("could not find matching '}' for PRESETS literal");
    process.exit(2);
}
// Include the trailing semicolon if it's there (the original ends `};`).
let blockEnd = end;
if (html[blockEnd] === ";") blockEnd++;

/* Render one preset as a JS template-literal entry. Backticks and `${`
 * are the only sequences that need escaping inside a template literal. */
function asJsTemplate(source) {
    return source
        .replace(/\\/g, "\\\\")
        .replace(/`/g, "\\`")
        .replace(/\$\{/g, "\\${");
}

const entries = manifest.presets.map(({ key, file }) => {
    const filePath = join(ROOT, file);
    let content;
    try {
        content = readFileSync(filePath, "utf8");
    } catch (e) {
        console.error(`bundle-presets: failed to read ${file}: ${e.message}`);
        process.exit(2);
    }
    return `  ${JSON.stringify(key)}: \`${asJsTemplate(content)}\`,`;
});

const replacement =
    `const PRESETS = {\n` +
    `  // AUTO-GENERATED — edit runtime/presets/manifest.json and the\n` +
    `  // referenced .lua files, then run \`node scripts/bundle-presets.mjs\`.\n` +
    entries.join("\n") +
    `\n};`;

const updated = html.slice(0, start) + replacement + html.slice(blockEnd);

if (updated === html) {
    console.log(`bundle-presets: ${mode === "check" ? "ok " : "no change ("}${manifest.presets.length} preset(s) in sync${mode === "check" ? "" : ")"}`);
    process.exit(0);
}

if (mode === "check") {
    console.error(
        `bundle-presets: drift detected — playground.html PRESETS block does not match the manifest.\n` +
        `Run \`node scripts/bundle-presets.mjs --write\` to regenerate.`);
    process.exit(1);
}

writeFileSync(playgroundPath, updated);
console.log(`bundle-presets: wrote ${manifest.presets.length} preset(s) to ${playgroundPath}`);
