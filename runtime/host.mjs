// Host runner for lua2wasm modules under Node.
// Usage: node host.mjs <module.wasm>
import { readFile } from "node:fs/promises";
import { readFileSync, writeFileSync, existsSync,
         unlinkSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { formatFloat, formatScalar, cFormatG } from "./format.mjs";
import { MATH_FNS, MATH2_FNS, makeHelpers,
         BufferedFile, parseFileMode,
         latin1Bytes, writeBytesToFmtBuf } from "./host-bindings.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) {
    console.error("usage: node host.mjs <module.wasm>");
    process.exit(2);
}

let instance;
const helpers = makeHelpers({ getInstance: () => instance, formatFloat, cFormatG });
const { luaToString, formatSpec, parseLuaNumber, osDate, osGetenv, objId } = helpers;

// Optional override for deterministic tests: if LUA2WASM_TEST_TIME is set
// (decimal unix seconds), `os.time()` and the implicit `os.date()` "now"
// will both use that value instead of Date.now().
const FROZEN_TIME = process.env.LUA2WASM_TEST_TIME
    ? BigInt(process.env.LUA2WASM_TEST_TIME) : null;
const cpuStart = process.cpuUsage();

const bytes = await readFile(wasmPath);

// io.read backing: stdin is just another BufferedFile, pulled in
// synchronously on first access and read through the same cursor/slice
// logic as on-disk files (no duplicated mode/regex handling).
let stdinFile = null;
function ensureStdin() {
    if (stdinFile !== null) return stdinFile;
    let bytes;
    // Read stdin as raw bytes (Lua strings are byte arrays); a "utf8" read
    // would mangle binary input.
    try { bytes = new Uint8Array(readFileSync(0)); }
    catch { bytes = new Uint8Array(0); }
    stdinFile = new BufferedFile(bytes);
    return stdinFile;
}
// mode 0 = "l", 1 = "L", 2 = "a", 3 = N-byte count. Mirrors fsRead's
// wrapping: write the slice into $fmt_buf and return its length, or -1 at
// EOF for line/N modes (mode 2 yields an empty slice -> 0, never -1).
function hostRead(mode, count) {
    const slice = ensureStdin().read(mode, count);
    if (slice === null) return -1;
    return writeBytesToFmtBuf(instance.exports, slice);
}
function hostReadNum() {
    const s = ensureStdin().readNumStr();
    return s === null ? null : helpers.parseNumberFromString(s);
}

// --- filesystem: an fd registry over node:fs, with BufferedFile doing
// the cursor/slice bookkeeping. The error convention matches the WAT
// side: a negative return means failure, with the message (the first
// (-ret - 1) bytes of $fmt_buf) built here so it can include the path. ---
const openFiles = new Map();   // fd -> { file: BufferedFile, path, writable }
let nextFd = 3;                // 0/1/2 are the conceptual std streams
function fmtBufBytes(bytes) {
    return writeBytesToFmtBuf(instance.exports, bytes);
}
function fmtBufErr(msg) {
    return -(fmtBufBytes(latin1Bytes(msg)) + 1);
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
    e.file.write(latin1Bytes(luaToString(valRef)));
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
    return fmtBufBytes(latin1Bytes(name));
}

({ instance } = await WebAssembly.instantiate(bytes, {
    host: {
        // luaToString yields a latin1 string (one char per Lua byte); write
        // the raw bytes via Buffer so the stream isn't re-encoded as UTF-8,
        // which would corrupt any non-UTF-8 byte (e.g. string.char(255)).
        print:     (v) => { process.stdout.write(Buffer.from(luaToString(v) + "\n", "latin1")); },
        write_raw: (v) => { process.stdout.write(Buffer.from(luaToString(v), "latin1")); },
        obj_id:    (v) => objId(v),
        write_err: (v) => { process.stderr.write(Buffer.from(luaToString(v), "latin1")); },
        warn:      (v) => { process.stderr.write(Buffer.from("Lua warning: " + luaToString(v) + "\n", "latin1")); },
        fmt:       (kind, i, f, prec) => {
            // Numbers only flow through here, so the output is ASCII; latin1
            // keeps it byte-exact and consistent with the other fmt_buf paths.
            return writeBytesToFmtBuf(instance.exports,
                latin1Bytes(formatScalar(kind, i, f, prec)));
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
        process.stderr.write(Buffer.from("lua: " + msg + "\n", "latin1"));
        process.exit(1);
    }
    throw e;
}
