// Host runner for lua2wasm modules.
// Usage: node runtime/host.mjs <module.wasm>
import { readFile } from "node:fs/promises";

const wasmPath = process.argv[2];
if (!wasmPath) {
    console.error("usage: node host.mjs <module.wasm>");
    process.exit(2);
}

function formatLuaValue(v) {
    if (v === null || v === undefined) return "nil";
    // i31ref values surface as plain JS numbers via JS API.
    if (typeof v === "number") return String(v);
    if (typeof v === "boolean") return v ? "true" : "false";
    if (typeof v === "string") return v;
    return String(v);
}

const bytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {
    host: {
        print: (v) => { process.stdout.write(formatLuaValue(v) + "\n"); },
    },
});

// `main` is the start function and runs on instantiate. Nothing else to do.
void instance;
