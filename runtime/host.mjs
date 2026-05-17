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
({ instance } = await WebAssembly.instantiate(bytes, {
    host: {
        print: (v) => { process.stdout.write(luaToString(v) + "\n"); },
    },
}));
instance.exports.main();
