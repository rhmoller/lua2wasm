// Host runner for lua2wasm modules under Node.
// Usage: node host.mjs <module.wasm>
import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { formatFloat, formatScalar } from "./format.mjs";
import { MATH_FNS, MATH2_FNS, makeHelpers } from "./host-bindings.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) {
    console.error("usage: node host.mjs <module.wasm>");
    process.exit(2);
}

let instance;
const helpers = makeHelpers({ getInstance: () => instance, formatFloat });
const { luaToString, formatSpec, parseLuaNumber } = helpers;

const bytes = await readFile(wasmPath);

// io.read backing: pulls all of stdin synchronously at first call and
// keeps a byte cursor.
let stdinBuf = null;
let stdinPos = 0;
function ensureStdin() {
    if (stdinBuf !== null) return;
    try {
        stdinBuf = new TextEncoder().encode(readFileSync(0, "utf8"));
    } catch { stdinBuf = new Uint8Array(0); }
}
function writeBytesToFmtBuf(slice) {
    for (let i = 0; i < slice.length; i++)
        instance.exports.fmt_buf_set(i, slice[i]);
    return slice.length;
}
// mode 0 = "l", 1 = "L", 2 = "a", 3 = N-byte count
function hostRead(mode, count) {
    ensureStdin();
    if (mode === 2) {
        const slice = stdinBuf.subarray(stdinPos);
        stdinPos = stdinBuf.length;
        return writeBytesToFmtBuf(slice);
    }
    if (mode === 3) {
        if (count === 0) return stdinPos >= stdinBuf.length ? -1 : 0;
        if (stdinPos >= stdinBuf.length) return -1;
        const end = Math.min(stdinPos + count, stdinBuf.length);
        const slice = stdinBuf.subarray(stdinPos, end);
        stdinPos = end;
        return writeBytesToFmtBuf(slice);
    }
    if (stdinPos >= stdinBuf.length) return -1;
    let end = stdinPos;
    while (end < stdinBuf.length && stdinBuf[end] !== 0x0A) end++;
    const includeNewline = mode === 1 && end < stdinBuf.length;
    const slice = stdinBuf.subarray(stdinPos, end + (includeNewline ? 1 : 0));
    stdinPos = end + (end < stdinBuf.length ? 1 : 0);
    return writeBytesToFmtBuf(slice);
}
function hostReadNum() {
    ensureStdin();
    while (stdinPos < stdinBuf.length) {
        const b = stdinBuf[stdinPos];
        if (b === 0x20 || b === 0x09 || b === 0x0A || b === 0x0D
         || b === 0x0B || b === 0x0C) stdinPos++;
        else break;
    }
    if (stdinPos >= stdinBuf.length) return null;
    const tail = new TextDecoder().decode(stdinBuf.subarray(stdinPos));
    const m = /^[+-]?(0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]*)?([pP][+-]?[0-9]+)?|[0-9]+\.?[0-9]*([eE][+-]?[0-9]+)?|\.[0-9]+([eE][+-]?[0-9]+)?)/.exec(tail);
    if (!m) return null;
    stdinPos += new TextEncoder().encode(m[0]).length;
    return helpers.parseNumberFromString(m[0]);
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
        math:      (kind, x)      => MATH_FNS[kind](x),
        math2:     (kind, x, y)   => MATH2_FNS[kind](x, y),
        parse_num: (s, base)      => parseLuaNumber(s, base),
        fmt_spec:  (spec, val)    => formatSpec(spec, val),
        read:      (mode, count)  => hostRead(mode, count),
        read_num:  ()             => hostReadNum(),
    },
}));
instance.exports.main();
