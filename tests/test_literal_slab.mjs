// node --test: every literal the runtime prelude addresses by absolute offset
// into the $str_data slab — the `(i32.const off) (i32.const len)` operands of
// $throw_lit / $throw_lit_at / $for_error and of `array.new_data … $str_data`
// — must lie inside one entry of LITERAL_SLAB in src/codegen/module.c. The slab's own
// consistency (offsets contiguous, bytes matching LITERAL_PREFIX) is checked
// by verify_literal_slab at compile time; this closes the other side: an edit
// that shifts the slab under an offset the prelude still uses.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const codegen = readFileSync(`${root}src/codegen/module.c`, "utf8");
const preludeDir = `${root}runtime/prelude/`;
const prelude = readdirSync(preludeDir)
    .filter(f => f.endsWith(".wat"))
    .map(f => readFileSync(preludeDir + f, "utf8"))
    .join("\n");

function slabEntries() {
    const start = codegen.indexOf("LITERAL_SLAB[] = {");
    const table = codegen.slice(start, codegen.indexOf("};", start));
    return [...table.matchAll(/\{(\d+), "((?:[^"\\]|\\.)*)"\}/g)].map(m => ({
        off: Number(m[1]),
        text: JSON.parse(`"${m[2]}"`),
    }));
}

function preludeRefs() {
    const code = prelude.split("\n").map(l => l.split(";;")[0]).join("\n");
    const pair = String.raw`\(i32\.const (\d+)\)\s+\(i32\.const (\d+)\)`;
    const forms = [
        new RegExp(String.raw`\$throw_lit(?:_at)?\s+` + pair, "g"),
        new RegExp(String.raw`\$str_data\s+` + pair, "g"),
        new RegExp(String.raw`\$for_error\s+\(local\.get \$\w+\)\s+` + pair, "g"),
    ];
    return forms.flatMap(re => [...code.matchAll(re)].map(m => ({ off: Number(m[1]), len: Number(m[2]), at: m[0] })));
}

test("the slab table parses", () => {
    const entries = slabEntries();
    assert.ok(entries.length > 40, `only ${entries.length} slab entries found`);
    assert.equal(entries[0].off, 0);
});

test("every prelude literal reference lies inside one slab entry", () => {
    const entries = slabEntries();
    const refs = preludeRefs();
    assert.ok(refs.length > 50, `only ${refs.length} literal references found`);
    for (const r of refs) {
        const inside = entries.some(e => e.off <= r.off && r.off + r.len <= e.off + e.text.length);
        assert.ok(inside, `${r.at} addresses bytes ${r.off}..${r.off + r.len}, which span no single slab entry`);
    }
});
