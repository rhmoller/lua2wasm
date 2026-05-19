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
const { luaToString, formatSpec, parseLuaNumber, osDate, osGetenv } = helpers;

// Optional override for deterministic tests: if LUA2WASM_TEST_TIME is set
// (decimal unix seconds), `os.time()` and the implicit `os.date()` "now"
// will both use that value instead of Date.now().
const FROZEN_TIME = process.env.LUA2WASM_TEST_TIME
    ? BigInt(process.env.LUA2WASM_TEST_TIME) : null;
const cpuStart = process.cpuUsage();

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
        warn:      (v) => { process.stderr.write("Lua warning: " + luaToString(v) + "\n"); },
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
        os_time:   ()             => FROZEN_TIME ?? BigInt(Math.floor(Date.now() / 1000)),
        os_clock:  ()             => {
            const u = process.cpuUsage(cpuStart);
            return (u.user + u.system) / 1e6;
        },
        os_getenv: (name)         => osGetenv(name),
        os_exit:   (code, hasCode) => process.exit(hasCode ? code : 0),
        os_date:   (fmt, time, hasTime) => osDate(fmt,
            (!hasTime && FROZEN_TIME !== null) ? FROZEN_TIME : time,
            hasTime || FROZEN_TIME !== null),
    },
}));
try {
    instance.exports.main();
} catch (e) {
    /* Uncaught Lua error: unwrap the $LuaError payload (exported tag
     * "LuaError") and print it via luaToString. Falls back to Node's
     * default formatting for any other exception. */
    const tag = instance.exports && instance.exports.LuaError;
    if (tag && e instanceof WebAssembly.Exception && e.is(tag)) {
        const payload = e.getArg(tag, 0);
        let msg;
        if (payload === null || payload === undefined) {
            /* Internal throw site with no message (e.g. argument-type
             * errors deep in the builtins). Recover the throw-site line
             * from the call-frame stack so the user at least knows where
             * to look. */
            const line = instance.exports.lua_error_line?.() ?? 0;
            const srcRef = instance.exports.lua_src_name?.();
            const src = srcRef ? luaToString(srcRef) : "?";
            msg = line ? `${src}:${line}: (nil error)` : "(nil error)";
        } else {
            msg = luaToString(payload);
        }
        process.stderr.write("lua: " + msg + "\n");
        process.exit(1);
    }
    throw e;
}
