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
export const MATH2_FNS = [Math.atan2, cPow];

// --- filesystem support, shared by the Node runner and the playground ---
//
// Both hosts keep an fd registry of open files; the actual byte storage
// differs (Node uses node:fs synchronously, the playground uses just-bash
// asynchronously via JSPI). The buffer/cursor logic in between is identical,
// so it lives here as a host-agnostic helper. The WAT side passes a read
// `mode` (0="l", 1="L", 2="a", 3=N bytes) and capped reads chunk through the
// shared 16 KB $fmt_buf, so a file larger than the buffer never overruns it.

export const FMT_BUF_CAP = 16384;

// Parse an io.open mode string into capability flags. A trailing "b"
// (binary) is accepted and ignored; we always operate on raw bytes.
// Returns null for an unrecognised mode.
//   needExisting: load current file contents at open time (r/r+/a/a+)
//   mustExist:    fail if the file is absent (r/r+)
export function parseFileMode(mode) {
    let s = (mode || "r").replace("b", "");
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
        const tail = new TextDecoder().decode(this.buf.subarray(this.pos));
        const m = /^[+-]?(0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]*)?([pP][+-]?[0-9]+)?|[0-9]+\.?[0-9]*([eE][+-]?[0-9]+)?|\.[0-9]+([eE][+-]?[0-9]+)?)/.exec(tail);
        if (!m) return null;
        this.pos += new TextEncoder().encode(m[0]).length;
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

// `tostring`-like rendering for the host; needed by formatSpec's `%s` /
// `%q` and the playground's print. Caller passes in formatFloat to keep
// dependency direction clean.
export function makeHelpers({ getInstance, formatFloat, cFormatG }) {
    const exp = () => getInstance().exports;

    function readLuaString(v) {
        const n = exp().lua_str_len(v);
        const out = new Uint8Array(n);
        for (let i = 0; i < n; i++) out[i] = exp().lua_str_byte(v, i);
        return new TextDecoder().decode(out);
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

    // Uses the module-level FMT_BUF_CAP (kept in sync with the $fmt_buf
    // size in stdlib_init); truncating beyond it is safer than walking off
    // the end of the GC array.
    function writeFmtBuf(s) {
        const bytes = new TextEncoder().encode(s);
        const n = Math.min(bytes.length, FMT_BUF_CAP);
        for (let i = 0; i < n; i++) exp().fmt_buf_set(i, bytes[i]);
        return n;
    }

    function applyPad(body, flags, width) {
        if (width <= body.length) return body;
        const pad = " ".repeat(width - body.length);
        return flags.includes("-") ? body + pad : pad + body;
    }

    function applyPadNumeric(body, flags, width) {
        if (width <= body.length) return body;
        if (flags.includes("-")) return body + " ".repeat(width - body.length);
        if (flags.includes("0")) {
            const m = /^([-+ ]?(?:0[xX])?)(.*)$/.exec(body);
            return m[1] + "0".repeat(width - body.length) + m[2];
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
            body = body.replace(/e([+-]?)(\d)$/, "e$10$2");
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

    function formatHexFloat(v, upper) {
        if (!Number.isFinite(v)) {
            if (Number.isNaN(v)) return upper ? "NAN" : "nan";
            return (v < 0 ? "-" : "") + (upper ? "INF" : "inf");
        }
        if (v === 0) return upper ? "0X0P+0" : "0x0p+0";
        const sign = v < 0 ? "-" : "";
        v = Math.abs(v);
        let e = Math.floor(Math.log2(v));
        let frac = v / Math.pow(2, e);
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
                  + "p" + (e >= 0 ? "+" : "") + e;
        return sign + (upper ? out.toUpperCase() : out);
    }

    // Matches reference Lua's addquoted: ", \ and newline become a backslash
    // followed by the character itself (so a literal "\n" is backslash + a real
    // newline). Other control chars become \ddd, padded to 3 digits only when
    // the next char is a digit (to keep the escape unambiguous).
    function quoteForLua(s) {
        let out = '"';
        for (let i = 0; i < s.length; i++) {
            const ch = s[i];
            const c = s.charCodeAt(i);
            if (ch === '"' || ch === "\\" || ch === "\n") {
                out += "\\" + ch;
            } else if (c < 32 || c === 127) {
                const nxt = s.charCodeAt(i + 1);
                const digits = String(c);
                out += "\\" + (nxt >= 48 && nxt <= 57 ? digits.padStart(3, "0") : digits);
            } else {
                out += ch;
            }
        }
        return out + '"';
    }

    function formatSpec(specRef, valRef) {
        const spec = readLuaString(specRef);
        const m = /^%([-+ #0']*)(\d*)(?:\.(\d+))?[hlLqjzt]*([%a-zA-Z])$/.exec(spec);
        if (!m) return writeFmtBuf(spec);
        const flags = m[1];
        const width = m[2] ? parseInt(m[2], 10) : 0;
        const prec  = m[3] !== undefined ? parseInt(m[3], 10) : -1;
        const conv  = m[4];
        const tag = valRef === null || valRef === undefined ? 0
                  : exp().lua_tag(valRef);
        // Integer argument for %d/%i/%u/%o/%x/%X/%c. Returns null when the
        // value has no integer representation (non-integral float, or a
        // non-numeric value) so the caller can raise a catchable error rather
        // than silently formatting 0. Numeric strings are coerced, like Lua.
        const asIntOrNull = () => {
            if (tag === 2) return exp().lua_get_int(valRef);
            if (tag === 3) {
                const f = exp().lua_get_float(valRef);
                return (Number.isFinite(f) && Number.isInteger(f)) ? BigInt(f) : null;
            }
            if (tag === 4) {
                const p = parseLuaNumber(valRef, 0);
                if (p === null || p === undefined) return null;
                const pt = exp().lua_tag(p);
                if (pt === 2) return exp().lua_get_int(p);
                if (pt === 3) {
                    const f = exp().lua_get_float(p);
                    return (Number.isFinite(f) && Number.isInteger(f)) ? BigInt(f) : null;
                }
            }
            return null;
        };
        const asFloat = () => {
            if (tag === 3) return exp().lua_get_float(valRef);
            if (tag === 2) return Number(exp().lua_get_int(valRef));
            return 0;
        };
        let body;
        switch (conv) {
            case "%": return writeFmtBuf(applyPad("%", flags, width));
            case "s": {
                let s = valRef === null || valRef === undefined ? "nil"
                      : tag === 4 ? readLuaString(valRef) : luaToString(valRef);
                if (prec >= 0 && s.length > prec) s = s.slice(0, prec);
                return writeFmtBuf(applyPad(s, flags, width));
            }
            case "q": {
                // %q must emit a value readable back as the SAME type: bare
                // number/true/false/nil literals, a quoted string, or a
                // round-trippable form for floats. Tables etc. have no literal
                // form -> -1 signals a catchable error to the WAT caller.
                if (tag === 0) return writeFmtBuf("nil");
                if (tag === 1) return writeFmtBuf(exp().lua_get_bool(valRef) ? "true" : "false");
                if (tag === 2) {
                    const iv = exp().lua_get_int(valRef);
                    // mininteger has no decimal literal that parses back.
                    return writeFmtBuf(iv === -(2n ** 63n) ? "0x8000000000000000" : String(iv));
                }
                if (tag === 3) {
                    const f = exp().lua_get_float(valRef);
                    if (Number.isNaN(f)) return writeFmtBuf("(0/0)");
                    if (f === Infinity) return writeFmtBuf("1e9999");
                    if (f === -Infinity) return writeFmtBuf("-1e9999");
                    return writeFmtBuf(formatHexFloat(f, false));
                }
                if (tag === 4) return writeFmtBuf(quoteForLua(readLuaString(valRef)));
                return -1;
            }
            case "c": {
                const iv = asIntOrNull(); if (iv === null) return -1;
                return writeFmtBuf(applyPad(
                    String.fromCharCode(Number(iv) & 0xff), flags, width));
            }
            case "d": case "i": {
                const iv = asIntOrNull(); if (iv === null) return -1;
                body = formatIntSpec(iv, 10, false, flags, prec);
                return writeFmtBuf(applyPadNumeric(body, flags, width));
            }
            case "u": {
                let v = asIntOrNull(); if (v === null) return -1;
                if (v < 0n) v += (1n << 64n);
                body = formatIntSpec(v, 10, false, flags, prec);
                return writeFmtBuf(applyPadNumeric(body, flags, width));
            }
            case "o": {
                const iv = asIntOrNull(); if (iv === null) return -1;
                body = formatIntSpec(iv, 8, false, flags, prec);
                if (flags.includes("#") && !body.replace(/^[-+ ]/, "").startsWith("0"))
                    body = body.replace(/^([-+ ]?)/, "$10");
                return writeFmtBuf(applyPadNumeric(body, flags, width));
            }
            case "x": {
                const iv = asIntOrNull(); if (iv === null) return -1;
                body = formatIntSpec(iv, 16, false, flags, prec);
                if (flags.includes("#") && iv !== 0n)
                    body = body.replace(/^([-+ ]?)/, "$10x");
                return writeFmtBuf(applyPadNumeric(body, flags, width));
            }
            case "X": {
                const iv = asIntOrNull(); if (iv === null) return -1;
                body = formatIntSpec(iv, 16, true, flags, prec);
                if (flags.includes("#") && iv !== 0n)
                    body = body.replace(/^([-+ ]?)/, "$10X");
                return writeFmtBuf(applyPadNumeric(body, flags, width));
            }
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
            return exp().lua_make_int(sign * BigInt(dec[2]));
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
        writeFmtBuf,
        formatSpec,
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
                return exp().lua_make_int(sign * BigInt(dec[2]));
            }
            const f = Number(s);
            return Number.isNaN(f) ? null : exp().lua_make_float(f);
        },
    };
}
