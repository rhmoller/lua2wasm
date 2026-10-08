// Shared host bindings — pure JS helpers used by both the Node runner
// (host.mjs) and the in-browser playground (playground.html).
//
// Pass in a `getInstance()` accessor so the helpers can reach
// `instance.exports.{lua_*,fmt_buf_set}` after instantiation completes.

export const MATH_FNS  = [Math.sin, Math.cos, Math.tan, Math.asin,
                          Math.acos, Math.atan, Math.exp, Math.log,
                          Math.log2, Math.log10];

// C pow() differs from JS Math.pow on IEEE-754 edge cases Lua relies on:
// pow(1, y) == 1 for any y (including inf/nan), and pow(±1, ±inf) == 1, where
// JS gives NaN for 1^inf. Match C so e.g. 1 ^ math.huge == 1.0.
export function cPow(x, y) {
    if (x === 1) return 1;
    if (x === -1 && (y === Infinity || y === -Infinity)) return 1;
    return Math.pow(x, y);
}
// JS `%` on numbers is the C fmod (truncated remainder), precise for all
// magnitudes — unlike a WAT `x - trunc(x/y)*y`, which cancels for large x.
export const MATH2_FNS = [Math.atan2, cPow, (x, y) => x % y];

// --- filesystem support, shared by the Node runner and the playground ---
//
// Both hosts keep an fd registry of open files; the actual byte storage
// differs (Node uses node:fs synchronously, the playground uses just-bash
// asynchronously via JSPI). The buffer/cursor logic in between is identical,
// so it lives here as a host-agnostic helper. The WAT side passes a read
// `mode` (0="l", 1="L", 2="a", 3=N bytes) and capped reads chunk through the
// shared 16 KB $fmt_buf, so a file larger than the buffer never overruns it.

export const FMT_BUF_CAP = 16384;

// Shared, reusable codec singletons. Constructing a TextEncoder/TextDecoder
// per I/O call is wasteful (they're stateless for our usage); hoist them so
// every path here and in host.mjs reuses the same instances.
export const UTF8_ENCODER = new TextEncoder();
export const UTF8_DECODER = new TextDecoder();

// Lua strings are arbitrary byte arrays, not UTF-8 text, so they must
// round-trip byte-for-byte through JS. We use latin1 (ISO-8859-1), the
// only encoding where each byte maps to exactly one code point (0x00..0xFF)
// and back — UTF-8 would mangle any non-UTF-8 byte into U+FFFD. ASCII (the
// only thing host-generated text ever contains) is a subset, so numbers,
// format output and error messages survive unchanged. Neither TextDecoder
// nor TextEncoder can do this: per the WHATWG Encoding standard the "latin1"
// label is an alias of windows-1252, which maps 0x80..0x9F to non-Latin-1
// code points (0x89 -> U+2030), and re-encoding by low byte then corrupts
// them. Both directions are hand-rolled.
export function latin1Decode(bytes) {
    let out = "";
    // String.fromCharCode.apply takes the whole chunk as arguments; keep the
    // chunks well under engine argument limits.
    for (let i = 0; i < bytes.length; i += 8192)
        out += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    return out;
}
export function latin1Bytes(s) {
    const b = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff;
    return b;
}

// Anchored match for one Lua numeric token (decimal/hex int or float, with
// optional sign and exponent). Shared by every "read a number from a byte
// stream" path (BufferedFile.readNumStr here, stdin's read_num in host.mjs)
// so the grammar stays in one place.
export const LUA_NUM_RE =
    /^[+-]?(0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]*)?([pP][+-]?[0-9]+)?|[0-9]+\.?[0-9]*([eE][+-]?[0-9]+)?|\.[0-9]+([eE][+-]?[0-9]+)?)/;

// The one place bytes go into the shared $fmt_buf. Every host I/O path that
// hands data back to the WAT side (file/stdin reads, formatted output, error
// messages, os.date) funnels through here. Truncating at FMT_BUF_CAP is safer
// than walking off the end of the GC array — the WAT side chunks larger reads.
export function writeBytesToFmtBuf(exports, bytes) {
    const n = Math.min(bytes.length, FMT_BUF_CAP);
    // Four bytes per crossing (see $fmt_buf_set_word); reads past the end of
    // a typed array are undefined -> 0, which the wasm side never stores.
    for (let i = 0; i < n; i += 4)
        exports.fmt_buf_set_word(i, bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16) | (bytes[i + 3] << 24), n);
    return n;
}

// Parse an io.open mode string into capability flags. A trailing "b"
// (binary) is accepted and ignored; we always operate on raw bytes.
// Returns null for an unrecognised mode.
//   needExisting: load current file contents at open time (r/r+/a/a+)
//   mustExist:    fail if the file is absent (r/r+)
export function parseFileMode(mode) {
    // Strip a single trailing "b" (binary) marker only — replacing the first
    // "b" anywhere would corrupt a mode that legitimately contained one.
    let s = (mode || "r").replace(/b$/, "");
    const plus = s.includes("+");
    const base = s[0];
    switch (base) {
        case "r": return { read: true,  write: plus, append: false,
                           needExisting: true,  mustExist: true };
        case "w": return { read: plus,  write: true, append: false,
                           needExisting: false, mustExist: false };
        case "a": return { read: plus,  write: true, append: true,
                           needExisting: true,  mustExist: false };
        default:  return null;
    }
}

// A whole-file byte buffer with a cursor. Reads slice from it; writes
// splice into it (extending as needed) and mark it dirty so the host
// knows to persist on flush/close.
export class BufferedFile {
    constructor(bytes, { append = false } = {}) {
        this.buf = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
        this.append = append;
        this.pos = append ? this.buf.length : 0;
        this.dirty = false;
    }

    // Returns a Uint8Array slice, or null at EOF for line / N-byte modes.
    // Mode 2 ("a") never returns null — an empty slice signals "no more".
    read(mode, count) {
        if (mode === 2) {
            if (this.pos >= this.buf.length) return new Uint8Array(0);
            const end = Math.min(this.pos + FMT_BUF_CAP, this.buf.length);
            const s = this.buf.subarray(this.pos, end);
            this.pos = end;
            return s;
        }
        if (mode === 3) {
            if (this.pos >= this.buf.length) return null;
            const end = Math.min(this.pos + count, this.buf.length);
            const s = this.buf.subarray(this.pos, end);
            this.pos = end;
            return s;
        }
        // line modes 0 ("l") and 1 ("L")
        if (this.pos >= this.buf.length) return null;
        let end = this.pos;
        while (end < this.buf.length && this.buf[end] !== 0x0A) end++;
        const includeNL = mode === 1 && end < this.buf.length;
        const s = this.buf.subarray(this.pos, end + (includeNL ? 1 : 0));
        this.pos = end + (end < this.buf.length ? 1 : 0);
        return s;
    }

    // Skip leading whitespace and return the matched numeric token (as a
    // string) per Lua syntax, advancing the cursor; null if none.
    readNumStr() {
        while (this.pos < this.buf.length) {
            const b = this.buf[this.pos];
            if (b === 0x20 || b === 0x09 || b === 0x0A || b === 0x0D
             || b === 0x0B || b === 0x0C) this.pos++;
            else break;
        }
        if (this.pos >= this.buf.length) return null;
        const tail = latin1Decode(this.buf.subarray(this.pos));
        const m = LUA_NUM_RE.exec(tail);
        if (!m) return null;
        // latin1: one matched char == one source byte, so advance by length.
        this.pos += m[0].length;
        return m[0];
    }

    write(bytes) {
        if (this.append) this.pos = this.buf.length;
        const end = this.pos + bytes.length;
        if (end > this.buf.length) {
            const nb = new Uint8Array(end);
            nb.set(this.buf);
            this.buf = nb;
        }
        this.buf.set(bytes, this.pos);
        this.pos = end;
        this.dirty = true;
    }

    // whence: 0 = set, 1 = cur, 2 = end. Returns the new position.
    seek(whence, offset) {
        const base = whence === 0 ? 0 : whence === 2 ? this.buf.length : this.pos;
        let np = base + offset;
        if (np < 0) np = 0;
        this.pos = np;
        return np;
    }

    contents() { return this.buf; }
}

// `tostring`-like rendering for the host; needed by print and `%s` /
// `%q` and the playground's print. Caller passes in formatFloat to keep
// dependency direction clean.
export function makeHelpers({ getInstance, formatFloat, cFormatG, cFormatF, cFormatE }) {
    const exp = () => getInstance().exports;

    function readLuaString(v) {
        const e = exp();
        const n = e.lua_str_len(v);
        const out = new Uint8Array(n);
        // Pull four bytes per crossing (packed little-endian); out-of-range
        // typed-array writes are silently ignored, so the tail needs no guard.
        for (let i = 0; i < n; i += 4) {
            const w = e.lua_str_word(v, i);
            out[i] = w;
            out[i + 1] = w >>> 8;
            out[i + 2] = w >>> 16;
            out[i + 3] = w >>> 24;
        }
        return latin1Decode(out);
    }

    // Stable, distinct per-object identity for the "type: 0xADDR" forms of
    // tostring / string.format("%p") on functions and strings. WasmGC objects
    // exposed to JS keep their identity across calls, so a WeakMap assigns each
    // a lazily-allocated id (only paid when an address is actually rendered).
    // Tables already carry their own struct $id and don't use this.
    // Ids feed an i32 WASM import ($host_obj_id) that renders them as an
    // unsigned hex address, so they live in the unsigned 32-bit range. Start
    // at 1 (0 is the "not an object" sentinel) and advance with `>>> 0` so the
    // counter stays unsigned: the old `(n+1)|0` produced a *signed* int that
    // turned negative past 2^31 and wrapped to 0 at 2^32, aliasing distinct
    // objects (and colliding with the sentinel) in %p / tostring.
    const objIds = new WeakMap();
    let nextObjId = 0;
    function objId(v) {
        if (v === null || typeof v !== "object") return 0;
        let id = objIds.get(v);
        if (id === undefined) { id = (nextObjId = (nextObjId + 1) >>> 0); objIds.set(v, id); }
        return id;
    }

    function luaToString(v) {
        if (v === null || v === undefined) return "nil";
        const tag = exp().lua_tag(v);
        switch (tag) {
            case 0: return "nil";
            case 1: return exp().lua_get_bool(v) ? "true" : "false";
            case 2: return String(exp().lua_get_int(v));
            case 3: return formatFloat(exp().lua_get_float(v));
            case 4: return readLuaString(v);
            case 5: return "function";
            case 6: return "table";
            default: return `<lua value tag=${tag}>`;
        }
    }

    // Encode a string and stream it into $fmt_buf via the shared byte writer.
    // latin1 so a Lua string's bytes (e.g. spliced in by string.format %s)
    // round-trip exactly rather than being re-encoded as UTF-8.
    function writeFmtBuf(s) {
        return writeBytesToFmtBuf(exp(), latin1Bytes(s));
    }


    function applyPadNumeric(body, flags, width) {
        if (width <= body.length) return body;
        if (flags.includes("-")) return body + " ".repeat(width - body.length);
        // '0' pads with zeros after the sign, except for inf/nan (C pads those
        // with spaces).
        if (flags.includes("0") && !/^[-+ ]?(inf|nan)$/i.test(body)) {
            const m = /^([-+ ]?(?:0[xX])?)(.*)$/.exec(body);
            return m[1] + "0".repeat(width - body.length) + m[2];
        }
        return " ".repeat(width - body.length) + body;
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
        const hash = flags.includes("#");
        if (conv === "f" || conv === "F") {
            body = cFormatF(v, prec);
            // '#' forces a decimal point even when precision 0 leaves none.
            if (hash && !body.includes(".")) body += ".";
        } else if (conv === "e" || conv === "E") {
            body = cFormatE(v, prec);
            if (hash && !body.includes(".")) body = body.replace("e", ".e");
        } else {
            // %g: faithful C printf semantics (exponent form below 1e-4 or at/
            // above `prec` significant digits), not JS toPrecision's thresholds.
            body = cFormatG(v, prec, !flags.includes("#"));
        }
        if (upper) body = body.toUpperCase();
        if (!body.startsWith("-")) {             // sign flags only when non-negative
            if (flags.includes("+")) body = "+" + body;
            else if (flags.includes(" ")) body = " " + body;
        }
        return body;
    }

    // Exact decomposition of a finite positive double: |x| = m * 2^e with m the
    // integer mantissa (implicit bit restored for normals).
    function splitDouble(x) {
        const dv = new DataView(new ArrayBuffer(8));
        dv.setFloat64(0, x);
        const hi = dv.getUint32(0), lo = dv.getUint32(4);
        const expBits = (hi >>> 20) & 0x7ff;
        let m = (BigInt(hi & 0xfffff) << 32n) | BigInt(lo >>> 0);
        if (expBits === 0) return { m, e: -1074 };
        return { m: m | (1n << 52n), e: expBits - 1075 };
    }

    // C "%a": 0x1.<hex>p<exp>. Without a precision the mantissa is exact with
    // trailing zeros stripped; with one it is rounded to that many hex digits
    // (ties to even, like glibc), a carry renormalising 0x1.fff -> 0x2.000.
    function formatHexFloat(v, upper, prec = -1) {
        if (!Number.isFinite(v)) {
            if (Number.isNaN(v)) return upper ? "NAN" : "nan";
            return (v < 0 ? "-" : "") + (upper ? "INF" : "inf");
        }
        const sign = v < 0 || Object.is(v, -0) ? "-" : "";
        let out;
        if (v === 0) {
            out = "0x0" + (prec > 0 ? "." + "0".repeat(prec) : "") + "p+0";
        } else {
            const { m, e } = splitDouble(Math.abs(v));       // |v| = m * 2^e exactly
            const bits = m.toString(2).length;                // m normalised: top bit is the unit
            let intPart = 1n, frac = m - (1n << BigInt(bits - 1));
            let fracBits = bits - 1, exp = e + bits - 1;
            let hex;
            if (prec < 0) {
                // pad the fraction to a nibble boundary, print, strip zeros
                const pad = (4 - (fracBits % 4)) % 4;
                hex = fracBits + pad > 0 ? (frac << BigInt(pad)).toString(16).padStart((fracBits + pad) / 4, "0") : "";
                hex = hex.replace(/0+$/, "");
            } else {
                const keep = 4 * prec;
                if (keep < fracBits) {
                    const drop = BigInt(fracBits - keep);
                    let q = frac >> drop;
                    const r = frac & ((1n << drop) - 1n), half = 1n << (drop - 1n);
                    if (r > half || (r === half && (q & 1n) === 1n)) q += 1n;
                    if (q === 1n << BigInt(keep)) { q = 0n; intPart += 1n; }
                    frac = q;
                } else {
                    frac <<= BigInt(keep - fracBits);
                }
                hex = prec > 0 ? frac.toString(16).padStart(prec, "0") : "";
            }
            out = "0x" + intPart.toString(16) + (hex ? "." + hex : "") + "p" + (exp >= 0 ? "+" : "") + exp;
        }
        return sign + (upper ? out.toUpperCase() : out);
    }


    // One float directive of string.format (%e %E %f %F %g %G %a %A), or the
    // %q form of a float: the WAT side has parsed and validated the directive
    // and hands over primitives only. Flag bits: 1 '-', 2 '+', 4 ' ', 8 '#',
    // 16 '0'. Writes the padded bytes into $fmt_buf, returns the count.
    function formatFloatDirective(conv, flagBits, width, prec, x) {
        const c = String.fromCharCode(conv);
        if (c === "q") {
            if (Number.isNaN(x)) return writeFmtBuf("(0/0)");
            if (x === Infinity) return writeFmtBuf("1e9999");
            if (x === -Infinity) return writeFmtBuf("-1e9999");
            return writeFmtBuf(formatHexFloat(x, false));
        }
        let flags = "";
        if (flagBits & 1) flags += "-";
        if (flagBits & 2) flags += "+";
        if (flagBits & 4) flags += " ";
        if (flagBits & 8) flags += "#";
        if (flagBits & 16) flags += "0";
        let body = (c === "a" || c === "A") ? formatHexFloat(x, c === "A", prec)
                                            : formatFloatSpec(x, c, prec, flags);
        if ((c === "a" || c === "A") && !body.startsWith("-")) {
            if (flags.includes("+")) body = "+" + body;
            else if (flags.includes(" ")) body = " " + body;
        }
        return writeFmtBuf(applyPadNumeric(body, flags, width));
    }

    function parseLuaNumber(strRef, base) {
        const s = readLuaString(strRef).trim();
        if (!s) return null;
        if (base !== 0) {
            if (base < 2 || base > 36) return null;
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
            return exp().lua_make_int(sign * acc);
        }
        const hex = /^([+-]?)0[xX]([0-9a-fA-F]+)$/.exec(s);
        if (hex) {
            const sign = hex[1] === "-" ? -1n : 1n;
            return exp().lua_make_int(sign * BigInt("0x" + hex[2]));
        }
        // Hex float: 0x mantissa with a '.' and/or a binary 'p' exponent
        // (JS Number() doesn't parse these). 0x1p4 -> 16.0, 0x.8 -> 0.5.
        const hf = /^([+-]?)0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?[0-9]+))?$/.exec(s);
        if (hf && (s.includes(".") || /[pP]/.test(s)) && (hf[2] || hf[3])) {
            const sign = hf[1] === "-" ? -1 : 1;
            let mant = 0;
            for (const ch of (hf[2] || "")) mant = mant * 16 + parseInt(ch, 16);
            let scale = 1;
            for (const ch of (hf[3] || "")) { scale /= 16; mant += parseInt(ch, 16) * scale; }
            const binExp = hf[4] !== undefined ? parseInt(hf[4], 10) : 0;
            return exp().lua_make_float(sign * mant * Math.pow(2, binExp));
        }
        const dec = /^([+-]?)([0-9]+)$/.exec(s);
        if (dec) {
            const sign = dec[1] === "-" ? -1n : 1n;
            const v = sign * BigInt(dec[2]);
            // A decimal integer too big for a Lua integer becomes a float
            // (the explicit-base and hex forms above wrap instead).
            if (v < -(2n ** 63n) || v > 2n ** 63n - 1n)
                return exp().lua_make_float(Number(s));
            return exp().lua_make_int(v);
        }
        if (/^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/.test(s)) {
            const f = Number(s);
            if (!Number.isNaN(f)) return exp().lua_make_float(f);
        }
        return null;
    }

    // os.date format: a tiny strftime subset, plus the special "*t" form.
    // The "*t" case writes 9 LE i32 fields into $fmt_buf and signals the
    // table-return path by returning -1; everything else writes the
    // rendered string into $fmt_buf and returns its byte length.
    function osDate(fmtRef, time, hasTime) {
        const utc = (s) => s.startsWith("!") ? [true, s.slice(1)] : [false, s];
        const fmtStr = fmtRef === null || fmtRef === undefined
            ? "%c" : readLuaString(fmtRef);
        const [useUTC, body] = utc(fmtStr);
        const dt = hasTime ? new Date(Number(time) * 1000) : new Date();
        const get = (kind) => {
            switch (kind) {
                case "Y": return useUTC ? dt.getUTCFullYear()  : dt.getFullYear();
                case "m": return useUTC ? dt.getUTCMonth() + 1 : dt.getMonth() + 1;
                case "d": return useUTC ? dt.getUTCDate()      : dt.getDate();
                case "H": return useUTC ? dt.getUTCHours()     : dt.getHours();
                case "M": return useUTC ? dt.getUTCMinutes()   : dt.getMinutes();
                case "S": return useUTC ? dt.getUTCSeconds()   : dt.getSeconds();
                case "w": return useUTC ? dt.getUTCDay()       : dt.getDay();
            }
            return 0;
        };
        const yday = () => {
            const y = useUTC ? dt.getUTCFullYear() : dt.getFullYear();
            const start = useUTC ? Date.UTC(y, 0, 1) : new Date(y, 0, 1).getTime();
            const now = useUTC ? Date.UTC(y, dt.getUTCMonth(), dt.getUTCDate())
                               : new Date(y, dt.getMonth(), dt.getDate()).getTime();
            return Math.floor((now - start) / 86400000) + 1;
        };
        if (body === "*t") {
            const fields = [
                get("Y"), get("m"), get("d"),
                get("H"), get("M"), get("S"),
                get("w") + 1,  // Lua wday: 1=Sun..7=Sat (JS: 0..6)
                yday(),
                // No DST info in a portable JS Date; report false for UTC,
                // otherwise infer by comparing offset against January.
                useUTC ? 0
                       : (dt.getTimezoneOffset() <
                          new Date(dt.getFullYear(), 0, 1).getTimezoneOffset()
                          ? 1 : 0),
            ];
            for (let i = 0; i < fields.length; i++) {
                const v = fields[i] | 0;
                const o = i * 4;
                exp().fmt_buf_set(o,     v        & 0xff);
                exp().fmt_buf_set(o + 1, (v >>> 8)  & 0xff);
                exp().fmt_buf_set(o + 2, (v >>> 16) & 0xff);
                exp().fmt_buf_set(o + 3, (v >>> 24) & 0xff);
            }
            return -1;
        }
        const pad2 = (n) => n < 10 ? "0" + n : "" + n;
        const pad2sp = (n) => n < 10 ? " " + n : "" + n;   // space-padded width 2
        // C-locale names (strftime); reference Lua uses the C locale.
        const WDAY = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                      "Friday", "Saturday"];
        const MON = ["January", "February", "March", "April", "May", "June",
                     "July", "August", "September", "October", "November",
                     "December"];
        const hour12 = () => { const h = get("H") % 12; return h === 0 ? 12 : h; };
        const out = body.replace(/%(.)/g, (_, c) => {
            switch (c) {
                case "Y": return "" + get("Y");
                case "y": return pad2(get("Y") % 100);
                case "m": return pad2(get("m"));
                case "d": return pad2(get("d"));
                case "e": return pad2sp(get("d"));
                case "H": return pad2(get("H"));
                case "I": return pad2(hour12());
                case "M": return pad2(get("M"));
                case "S": return pad2(get("S"));
                case "j": return ("" + yday()).padStart(3, "0");
                case "w": return "" + get("w");
                case "a": return WDAY[get("w")].slice(0, 3);
                case "A": return WDAY[get("w")];
                case "b": case "h": return MON[get("m") - 1].slice(0, 3);
                case "B": return MON[get("m") - 1];
                case "p": return get("H") < 12 ? "AM" : "PM";
                case "c": return `${WDAY[get("w")].slice(0, 3)} ${MON[get("m") - 1].slice(0, 3)} `
                                 + `${pad2sp(get("d"))} ${pad2(get("H"))}:${pad2(get("M"))}:`
                                 + `${pad2(get("S"))} ${get("Y")}`;
                case "x": return `${pad2(get("m"))}/${pad2(get("d"))}/${pad2(get("Y") % 100)}`;
                case "X": return pad2(get("H")) + ":" + pad2(get("M")) + ":" + pad2(get("S"));
                case "%": return "%";
                default:  return "%" + c;
            }
        });
        return writeFmtBuf(out);
    }

    function osGetenv(nameRef) {
        const v = process?.env?.[readLuaString(nameRef)];
        if (v === undefined) return -1;
        return writeFmtBuf(v);
    }

    return {
        readLuaString,
        luaToString,
        objId,
        writeFmtBuf,
        formatFloatDirective,
        parseLuaNumber,
        osDate,
        osGetenv,
        // Convenience for parse-number-from-a-string-buffer:
        parseNumberFromString(text) {
            const s = text.trim();
            if (!s) return null;
            const hex = /^([+-]?)0[xX]([0-9a-fA-F]+)(\.[0-9a-fA-F]*)?([pP][+-]?[0-9]+)?$/.exec(s);
            if (hex && !hex[3] && !hex[4]) {
                const sign = hex[1] === "-" ? -1n : 1n;
                return exp().lua_make_int(sign * BigInt("0x" + hex[2]));
            }
            const dec = /^([+-]?)([0-9]+)$/.exec(s);
            if (dec) {
                const sign = dec[1] === "-" ? -1n : 1n;
                const v = sign * BigInt(dec[2]);
                if (v < -(2n ** 63n) || v > 2n ** 63n - 1n)
                    return exp().lua_make_float(Number(s));
                return exp().lua_make_int(v);
            }
            const f = Number(s);
            return Number.isNaN(f) ? null : exp().lua_make_float(f);
        },
    };
}
