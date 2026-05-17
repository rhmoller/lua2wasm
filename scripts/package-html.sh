#!/usr/bin/env bash
# Package a compiled .wasm + host loader into one self-contained .html file.
# Usage: scripts/package-html.sh <module.wasm> [-o out.html]
set -euo pipefail

WASM=""
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) OUT="$2"; shift 2 ;;
        *)  WASM="$1"; shift ;;
    esac
done

if [[ -z "$WASM" ]]; then
    echo "usage: $0 <module.wasm> [-o out.html]" >&2
    exit 2
fi
if [[ -z "$OUT" ]]; then
    OUT="${WASM%.wasm}.html"
fi

BASE64="$(base64 -w0 "$WASM")"

cat > "$OUT" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>lua2wasm: $(basename "$WASM")</title>
<style>
  body { font: 14px/1.4 system-ui, sans-serif; margin: 2em auto; max-width: 60em; padding: 0 1em; }
  pre  { background: #111; color: #eee; padding: 1em; border-radius: 4px; white-space: pre-wrap; }
  h1   { font-size: 1.1em; color: #555; }
</style>
<h1>lua2wasm output — $(basename "$WASM")</h1>
<pre id="out"></pre>
<script type="module">
const out = document.getElementById("out");
const wbuf = Uint8Array.from(atob("${BASE64}"), c => c.charCodeAt(0));

let instance;
function readLuaString(v) {
  const n = instance.exports.lua_str_len(v);
  const arr = new Uint8Array(n);
  for (let i = 0; i < n; i++) arr[i] = instance.exports.lua_str_byte(v, i);
  return new TextDecoder().decode(arr);
}
function formatFloat(f) {
  if (!Number.isFinite(f)) return f === Infinity ? "inf" : f === -Infinity ? "-inf" : "nan";
  if (Number.isInteger(f)) return \`\${f}.0\`;
  return f.toPrecision(14).replace(/\\.?0+(e|\$)/, "\$1");
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
    default: return \`<lua value tag=\${tag}>\`;
  }
}

({ instance } = await WebAssembly.instantiate(wbuf, {
  host: { print: v => { out.textContent += luaToString(v) + "\\n"; } },
}));
try { instance.exports.main(); }
catch (e) { out.textContent += "ERROR: " + e + "\\n"; }
</script>
EOF
echo "wrote $OUT"
