#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/attributes.lua"
WAT="$BUILD_DIR/attributes.wat"
WASM="$BUILD_DIR/attributes.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'3.14
1\t3
inside do
closing\tsecond\t(no err)
closing\tfirst\t(no err)
after do
body
closing\tG\t(no err)
end
noclose-pcall returned ok =\tfalse
hi'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi

# Also verify <const> rejection happens at compile time.
cat > "$BUILD_DIR/attributes_const_reject.lua" <<'EOF'
local x <const> = 1
x = 2
EOF
if "$BIN" "$BUILD_DIR/attributes_const_reject.lua" -o "$BUILD_DIR/attributes_const_reject.wat" 2>/dev/null; then
    echo "FAIL: <const> reassignment was accepted" >&2
    exit 1
fi
