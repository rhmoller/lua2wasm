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
const MATH2_FNS = [Math.atan2, Math.pow];

// Parse a Lua-string anyref per Lua semantics and return the appropriate
// Lua value (int / float / null). Implements the manual's tonumber rules:
//   - trim ASCII whitespace at both ends
//   - empty -> nil
//   - optional + / - sign
//   - base == 0: integer (decimal, or hex with 0x/0X prefix) OR float;
//     int form is preferred when it parses cleanly
//   - base in [2, 36]: integer in that base only; sign + digits, no
//     fractional / exponent / 0x prefix
function parseLuaNumber(strRef, base) {
    // Lua whitespace (\t \n \v \f \r space) is a subset of JS \s.
    const s = readLuaString(strRef).trim();
    if (!s) return null;
    if (base !== 0) {
        if (base < 2 || base > 36) return null;
        // sign + digits only
        const m = /^([+-]?)([0-9a-zA-Z]+)$/.exec(s);
        if (!m) return null;
        const sign = m[1] === "-" ? -1n : 1n;
        const digits = m[2].toLowerCase();
        let acc = 0n;
        const baseB = BigInt(base);
        for (const ch of digits) {
            let d;
            if (ch >= "0" && ch <= "9") d = ch.charCodeAt(0) - 48;
            else d = ch.charCodeAt(0) - 97 + 10;
            if (d < 0 || d >= base) return null;
            acc = acc * baseB + BigInt(d);
        }
        return instance.exports.lua_make_int(sign * acc);
    }
    // base 0: try integer (decimal or hex) first, then float.
    // Hex integer: optional sign, 0x or 0X, hex digits.
    const hex = /^([+-]?)0[xX]([0-9a-fA-F]+)$/.exec(s);
    if (hex) {
        const sign = hex[1] === "-" ? -1n : 1n;
        return instance.exports.lua_make_int(sign * BigInt("0x" + hex[2]));
    }
    // Decimal integer: optional sign, digits, no '.' or 'e'.
    const dec = /^([+-]?)([0-9]+)$/.exec(s);
    if (dec) {
        const sign = dec[1] === "-" ? -1n : 1n;
        return instance.exports.lua_make_int(sign * BigInt(dec[2]));
    }
    // Float: optional sign, digits with '.' and/or exponent.
    if (/^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/.test(s)) {
        const f = Number(s);
        if (!Number.isNaN(f)) return instance.exports.lua_make_float(f);
    }
    return null;
}

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
        parse_num: (s, base) => parseLuaNumber(s, base),
        read:      () => {
            const s = readNextLine();
            if (s === null) return -1;
            for (let j = 0; j < s.length; j++) instance.exports.fmt_buf_set(j, s.charCodeAt(j));
            return s.length;
        },
    },
}));
instance.exports.main();
