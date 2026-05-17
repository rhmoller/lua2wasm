// Host runner for lua2wasm modules.
// Usage: node runtime/host.mjs <module.wasm>
import { readFile } from "node:fs/promises";

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

function formatFloat(f) {
    if (!Number.isFinite(f)) {
        return f === Infinity ? "inf" : f === -Infinity ? "-inf" : "nan";
    }
    if (Number.isInteger(f)) return `${f}.0`;
    // Lua's default is %.14g; mimic crudely.
    return f.toPrecision(14).replace(/\.?0+(e|$)/, "$1");
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
function formatScalar(kind, i, f, prec) {
    if (prec < 0) prec = 6;
    switch (kind) {
        case 0: return String(i);              // %d
        case 2: return Number(f).toPrecision(prec === 6 ? 14 : prec).replace(/\.?0+(e|$)/, "$1");  // %g
        case 3: return Number(f).toFixed(prec);                                     // %f
        case 4: return Number(f).toExponential(prec === 6 ? 1 : prec);              // %e
        case 5: return BigInt(i).toString(16);                                       // %x
        default: return "";
    }
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
    },
}));
instance.exports.main();
