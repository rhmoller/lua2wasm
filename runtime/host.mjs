// Host runner for lua2wasm modules.
// Usage: node runtime/host.mjs <module.wasm>
import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { formatFloat, formatScalar } from "./format.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) {
    console.error("usage: node host.mjs <module.wasm>");
    process.exit(2);
}

let instance;

function readLuaString(v) {
    const n = instance.exports.lua_str_len(v);
    const out = new Uint8Array(n);
    for (let i = 0; i < n; i++) out[i] = instance.exports.lua_str_byte(v, i);
    return new TextDecoder().decode(out);
}

function luaToString(v) {
    if (v === null || v === undefined) return "nil";
    const tag = instance.exports.lua_tag(v);
    switch (tag) {
        case 0: return "nil";
        case 1: return instance.exports.lua_get_bool(v) ? "true" : "false";
        case 2: return String(instance.exports.lua_get_int(v));
        case 3: return formatFloat(instance.exports.lua_get_float(v));
        case 4: return readLuaString(v);
        case 5: return "function";
        case 6: return "table";
        default: return `<lua value tag=${tag}>`;
    }
}

const bytes = await readFile(wasmPath);

const MATH_FNS = [Math.sin, Math.cos, Math.tan, Math.asin, Math.acos, Math.atan, Math.exp, Math.log];
const MATH2_FNS = [Math.atan2];

// io.read backing: read all of stdin synchronously at first call, hand out one
// line per io.read(). EOF → length -1.
let stdinLines = null;
function readNextLine() {
    if (stdinLines === null) {
        try {
            const data = readFileSync(0, "utf8");
            stdinLines = data.split("\n");
            if (stdinLines.length && stdinLines[stdinLines.length - 1] === "") stdinLines.pop();
        } catch { stdinLines = []; }
    }
    return stdinLines.length ? stdinLines.shift() : null;
}

({ instance } = await WebAssembly.instantiate(bytes, {
    host: {
        print:     (v) => { process.stdout.write(luaToString(v) + "\n"); },
        write_raw: (v) => { process.stdout.write(luaToString(v)); },
        fmt:       (kind, i, f, prec) => {
            const s = formatScalar(kind, i, f, prec);
            for (let j = 0; j < s.length; j++) instance.exports.fmt_buf_set(j, s.charCodeAt(j));
            return s.length;
        },
        math:      (kind, x) => MATH_FNS[kind](x),
        math2:     (kind, x, y) => MATH2_FNS[kind](x, y),
        read:      () => {
            const s = readNextLine();
            if (s === null) return -1;
            for (let j = 0; j < s.length; j++) instance.exports.fmt_buf_set(j, s.charCodeAt(j));
            return s.length;
        },
    },
}));
instance.exports.main();
