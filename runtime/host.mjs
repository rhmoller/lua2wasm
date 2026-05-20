// Host runner for lua2wasm modules under Node.
// Usage: node host.mjs <module.wasm>
import { readFile } from "node:fs/promises";
import { readFileSync, writeFileSync, existsSync,
         unlinkSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { formatFloat, formatScalar, cFormatG } from "./format.mjs";
import { MATH_FNS, MATH2_FNS, makeHelpers,
         BufferedFile, parseFileMode, FMT_BUF_CAP } from "./host-bindings.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) {
    console.error("usage: node host.mjs <module.wasm>");
    process.exit(2);
}

let instance;
const helpers = makeHelpers({ getInstance: () => instance, formatFloat, cFormatG });
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
    const n = Math.min(slice.length, FMT_BUF_CAP);
    for (let i = 0; i < n; i++)
        instance.exports.fmt_buf_set(i, slice[i]);
    return n;
}
// mode 0 = "l", 1 = "L", 2 = "a", 3 = N-byte count
function hostRead(mode, count) {
    ensureStdin();
    if (mode === 2) {
        // Chunked: hand back at most a buffer's worth and advance the
        // cursor; 0 at EOF lets the WAT "a" loop terminate.
        if (stdinPos >= stdinBuf.length) return 0;
        const end = Math.min(stdinPos + FMT_BUF_CAP, stdinBuf.length);
        const slice = stdinBuf.subarray(stdinPos, end);
        stdinPos = end;
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

// --- filesystem: an fd registry over node:fs, with BufferedFile doing
// the cursor/slice bookkeeping. The error convention matches the WAT
// side: a negative return means failure, with the message (the first
// (-ret - 1) bytes of $fmt_buf) built here so it can include the path. ---
const openFiles = new Map();   // fd -> { file: BufferedFile, path, writable }
let nextFd = 3;                // 0/1/2 are the conceptual std streams
function fmtBufBytes(bytes) {
    const n = Math.min(bytes.length, FMT_BUF_CAP);
    for (let i = 0; i < n; i++) instance.exports.fmt_buf_set(i, bytes[i]);
    return n;
}
function fmtBufErr(msg) {
    return -(fmtBufBytes(new TextEncoder().encode(msg)) + 1);
}
function errnoText(e) {
    switch (e && e.code) {
        case "ENOENT": return "No such file or directory";
        case "EACCES": return "Permission denied";
        case "EISDIR": return "Is a directory";
        case "ENOTDIR": return "Not a directory";
        case "EEXIST": return "File exists";
        default: return (e && e.message) || "I/O error";
    }
}
function fsOpen(pathRef, modeRef) {
    const path = luaToString(pathRef);
    const m = parseFileMode(modeRef ? luaToString(modeRef) : "r");
    if (!m) return fmtBufErr(path + ": invalid mode");
    let bytes;
    try {
        if (m.needExisting) {
            if (existsSync(path)) bytes = new Uint8Array(readFileSync(path));
            else if (m.mustExist)
                return fmtBufErr(path + ": No such file or directory");
            else bytes = new Uint8Array(0);
        } else {
            bytes = new Uint8Array(0);   // w / w+ truncate
        }
    } catch (e) { return fmtBufErr(path + ": " + errnoText(e)); }
    const fd = nextFd++;
    openFiles.set(fd, { file: new BufferedFile(bytes, { append: m.append }),
                        path, writable: m.write });
    return fd;
}
function fsRead(fd, mode, count) {
    const e = openFiles.get(fd);
    if (!e) return -1;
    const slice = e.file.read(mode, count);
    if (slice === null) return -1;
    return fmtBufBytes(slice);
}
function fsReadNum(fd) {
    const e = openFiles.get(fd);
    if (!e) return null;
    const s = e.file.readNumStr();
    return s === null ? null : helpers.parseNumberFromString(s);
}
function fsWrite(fd, valRef) {
    const e = openFiles.get(fd);
    if (!e) return -1;
    e.file.write(new TextEncoder().encode(luaToString(valRef)));
    return 0;
}
function fsSeek(fd, whence, offset) {
    const e = openFiles.get(fd);
    if (!e) return -1n;
    return BigInt(e.file.seek(whence, Number(offset)));
}
function fsFlush(fd) {
    const e = openFiles.get(fd);
    if (!e) return -1;
    if (e.writable && e.file.dirty) {
        try { writeFileSync(e.path, Buffer.from(e.file.contents())); }
        catch (err) { return fmtBufErr(e.path + ": " + errnoText(err)); }
        e.file.dirty = false;
    }
    return 0;
}
function fsClose(fd) {
    const r = fsFlush(fd);
    openFiles.delete(fd);
    return r < 0 ? r : 0;
}
function osRemove(pathRef) {
    const path = luaToString(pathRef);
    try { unlinkSync(path); return 0; }
    catch (e) { return fmtBufErr(path + ": " + errnoText(e)); }
}
function osRename(oldRef, newRef) {
    const o = luaToString(oldRef), n = luaToString(newRef);
    try { renameSync(o, n); return 0; }
    catch (e) { return fmtBufErr(o + ": " + errnoText(e)); }
}
function osTmpname() {
    const name = join(tmpdir(),
        "lua_" + Date.now().toString(36) + "_" + Math.random().toString(36).slice(2));
    return fmtBufBytes(new TextEncoder().encode(name));
}

({ instance } = await WebAssembly.instantiate(bytes, {
    host: {
        print:     (v) => { process.stdout.write(luaToString(v) + "\n"); },
        write_raw: (v) => { process.stdout.write(luaToString(v)); },
        write_err: (v) => { process.stderr.write(luaToString(v)); },
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
        os_time_table: (y, mo, d, h, mi, s) =>
            BigInt(Math.floor(new Date(Number(y), Number(mo) - 1, Number(d),
                Number(h), Number(mi), Number(s)).getTime() / 1000)),
        os_clock:  ()             => {
            const u = process.cpuUsage(cpuStart);
            return (u.user + u.system) / 1e6;
        },
        os_getenv: (name)         => osGetenv(name),
        os_exit:   (code, hasCode) => process.exit(hasCode ? code : 0),
        os_date:   (fmt, time, hasTime) => osDate(fmt,
            (!hasTime && FROZEN_TIME !== null) ? FROZEN_TIME : time,
            hasTime || FROZEN_TIME !== null),
        fs_open:     (path, mode)        => fsOpen(path, mode),
        fs_read:     (fd, mode, count)   => fsRead(fd, mode, count),
        fs_read_num: (fd)                => fsReadNum(fd),
        fs_write:    (fd, val)           => fsWrite(fd, val),
        fs_seek:     (fd, whence, off)   => fsSeek(fd, whence, off),
        fs_flush:    (fd)                => fsFlush(fd),
        fs_close:    (fd)                => fsClose(fd),
        os_remove:   (path)             => osRemove(path),
        os_rename:   (oldp, newp)       => osRename(oldp, newp),
        os_tmpname:  ()                 => osTmpname(),
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
