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

// --- string.format helpers ---
// formatSpec implements one Lua-style format directive (the bytes from
// `%` through the conversion char, e.g. "%-10s" or "%05.2f"). It writes
// the result into the shared fmt_buf and returns the byte length.
function formatSpec(specRef, valRef) {
    const spec = readLuaString(specRef);
    // %[flags][width][.precision][length]conv
    const m = /^%([-+ #0']*)(\d*)(?:\.(\d+))?[hlLqjzt]*([%a-zA-Z])$/.exec(spec);
    if (!m) return writeFmtBuf(spec);
    const flags = m[1];
    const width = m[2] ? parseInt(m[2], 10) : 0;
    const prec  = m[3] !== undefined ? parseInt(m[3], 10) : -1;
    const conv  = m[4];
    const tag = valRef === null || valRef === undefined ? 0
              : instance.exports.lua_tag(valRef);
    const asInt = () => {
        if (tag === 2) return instance.exports.lua_get_int(valRef);
        if (tag === 3) {
            const f = instance.exports.lua_get_float(valRef);
            if (Number.isFinite(f) && Number.isInteger(f)) return BigInt(f);
        }
        return 0n;
    };
    const asFloat = () => {
        if (tag === 3) return instance.exports.lua_get_float(valRef);
        if (tag === 2) return Number(instance.exports.lua_get_int(valRef));
        return 0;
    };
    let body;
    switch (conv) {
        case "%": return writeFmtBuf(applyPad("%", flags, width, true));
        case "s": {
            let s = valRef === null || valRef === undefined ? "nil"
                  : tag === 4 ? readLuaString(valRef) : luaToString(valRef);
            if (prec >= 0 && s.length > prec) s = s.slice(0, prec);
            return writeFmtBuf(applyPad(s, flags, width, true));
        }
        case "q": {
            const s = valRef === null || valRef === undefined ? "nil"
                    : tag === 4 ? readLuaString(valRef) : luaToString(valRef);
            return writeFmtBuf(quoteForLua(s));
        }
        case "c":
            return writeFmtBuf(applyPad(String.fromCharCode(Number(asInt()) & 0xff),
                                         flags, width, true));
        case "d": case "i":
            body = formatIntSpec(asInt(), 10, false, flags, prec);
            return writeFmtBuf(applyPadNumeric(body, flags, width));
        case "u": {
            let v = asInt(); if (v < 0n) v += (1n << 64n);
            body = formatIntSpec(v, 10, false, flags, prec);
            return writeFmtBuf(applyPadNumeric(body, flags, width));
        }
        case "o":
            body = formatIntSpec(asInt(), 8, false, flags, prec);
            if (flags.includes("#") && !body.replace(/^[-+ ]/, "").startsWith("0"))
                body = body.replace(/^([-+ ]?)/, "$10");
            return writeFmtBuf(applyPadNumeric(body, flags, width));
        case "x":
            body = formatIntSpec(asInt(), 16, false, flags, prec);
            if (flags.includes("#") && asInt() !== 0n)
                body = body.replace(/^([-+ ]?)/, "$10x");
            return writeFmtBuf(applyPadNumeric(body, flags, width));
        case "X":
            body = formatIntSpec(asInt(), 16, true, flags, prec);
            if (flags.includes("#") && asInt() !== 0n)
                body = body.replace(/^([-+ ]?)/, "$10X");
            return writeFmtBuf(applyPadNumeric(body, flags, width));
        case "f": case "F": case "e": case "E": case "g": case "G":
            body = formatFloatSpec(asFloat(), conv, prec, flags);
            return writeFmtBuf(applyPadNumeric(body, flags, width));
        case "a": case "A":
            body = formatHexFloat(asFloat(), conv === "A");
            return writeFmtBuf(applyPadNumeric(body, flags, width));
        default:
            return writeFmtBuf(spec);
    }
}

function writeFmtBuf(s) {
    const bytes = new TextEncoder().encode(s);
    for (let i = 0; i < bytes.length; i++) instance.exports.fmt_buf_set(i, bytes[i]);
    return bytes.length;
}

// Pad for non-numeric or %% — pad char is always space.
function applyPad(body, flags, width) {
    if (width <= body.length) return body;
    const pad = " ".repeat(width - body.length);
    return flags.includes("-") ? body + pad : pad + body;
}

// Pad for numeric conversions: '0' flag (no '-') means zero-fill after
// any sign / 0x prefix; otherwise space-pad.
function applyPadNumeric(body, flags, width) {
    if (width <= body.length) return body;
    if (flags.includes("-")) return body + " ".repeat(width - body.length);
    if (flags.includes("0")) {
        // Move sign / 0x / 0X to the front, then zero-fill between it
        // and the digits.
        const m = /^([-+ ]?(?:0[xX])?)(.*)$/.exec(body);
        const prefix = m[1], rest = m[2];
        const need = width - body.length;
        return prefix + "0".repeat(need) + rest;
    }
    return " ".repeat(width - body.length) + body;
}

function formatIntSpec(v, base, upper, flags, prec) {
    let bi = typeof v === "bigint" ? v : BigInt(v);
    const neg = bi < 0n;
    if (neg) bi = -bi;
    let s = bi.toString(base);
    if (upper) s = s.toUpperCase();
    if (prec >= 0) {
        if (prec === 0 && bi === 0n) s = "";
        else if (s.length < prec) s = "0".repeat(prec - s.length) + s;
    }
    if (neg) return "-" + s;
    if (flags.includes("+")) return "+" + s;
    if (flags.includes(" ")) return " " + s;
    return s;
}

function formatFloatSpec(v, conv, prec, flags) {
    const upper = conv === conv.toUpperCase();
    if (!Number.isFinite(v)) {
        if (Number.isNaN(v)) return upper ? "NAN" : "nan";
        const sign = v < 0 ? "-" : (flags.includes("+") ? "+"
                                  : flags.includes(" ") ? " " : "");
        return sign + (upper ? "INF" : "inf");
    }
    if (prec < 0) prec = 6;
    let body;
    if (conv === "f" || conv === "F") {
        body = v.toFixed(prec);
    } else if (conv === "e" || conv === "E") {
        body = v.toExponential(prec);
        body = body.replace(/e([+-]?)(\d)$/, "e$10$2");  // pad exp to 2 digits
    } else {
        // %g / %G
        if (prec === 0) prec = 1;
        body = v.toPrecision(prec);
        if (!flags.includes("#")) body = body.replace(/\.?0+(e|$)/, "$1");
        body = body.replace(/e([+-]?)(\d)$/, "e$10$2");
    }
    if (upper) body = body.toUpperCase();
    if (v >= 0) {
        if (flags.includes("+")) body = "+" + body;
        else if (flags.includes(" ")) body = " " + body;
    }
    return body;
}

function formatHexFloat(v, upper) {
    if (!Number.isFinite(v)) {
        if (Number.isNaN(v)) return upper ? "NAN" : "nan";
        return (v < 0 ? "-" : "") + (upper ? "INF" : "inf");
    }
    if (v === 0) return upper ? "0X0P+0" : "0x0p+0";
    const sign = v < 0 ? "-" : "";
    v = Math.abs(v);
    let exp = Math.floor(Math.log2(v));
    let frac = v / Math.pow(2, exp);
    let intPart = Math.floor(frac);
    let f = frac - intPart;
    let hex = intPart.toString(16);
    let fracHex = "";
    for (let i = 0; i < 13 && f > 0; i++) {
        f *= 16;
        const d = Math.floor(f);
        fracHex += d.toString(16);
        f -= d;
    }
    fracHex = fracHex.replace(/0+$/, "");
    const out = "0x" + hex + (fracHex ? "." + fracHex : "")
              + "p" + (exp >= 0 ? "+" : "") + exp;
    return sign + (upper ? out.toUpperCase() : out);
}

function quoteForLua(s) {
    let out = '"';
    for (let i = 0; i < s.length; i++) {
        const ch = s[i];
        const c = s.charCodeAt(i);
        if (ch === '"' || ch === "\\") out += "\\" + ch;
        else if (ch === "\n") out += "\\n";
        else if (ch === "\r") out += "\\r";
        else if (c === 0) {
            const nxt = s.charCodeAt(i + 1);
            out += (nxt >= 48 && nxt <= 57) ? "\\000" : "\\0";
        } else if (c < 32 || c === 127) out += "\\" + c;
        else out += ch;
    }
    return out + '"';
}

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
        fmt_spec:  (spec, val) => formatSpec(spec, val),
        read:      () => {
            const s = readNextLine();
            if (s === null) return -1;
            for (let j = 0; j < s.length; j++) instance.exports.fmt_buf_set(j, s.charCodeAt(j));
            return s.length;
        },
    },
}));
instance.exports.main();
