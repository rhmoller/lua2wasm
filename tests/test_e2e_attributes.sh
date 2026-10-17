#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/attributes.lua"
WAT="$BUILD_DIR/attributes.wat"
WASM="$BUILD_DIR/attributes.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
"$BUILD_DIR/wat2wasm" -o "$WASM" "$WAT"

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

# A local list may declare only one to-be-closed variable, in either the
# per-name or the prefix (`local <close> a, b`) form; rejected at compile time.
for decl in 'local a <close>, b <close> = nil, nil' 'local <close> a, b = nil, nil'; do
    printf '%s\n' "$decl" > "$BUILD_DIR/attributes_multi_close.lua"
    if ERR="$("$BIN" "$BUILD_DIR/attributes_multi_close.lua" -o "$BUILD_DIR/attributes_multi_close.wat" 2>&1)"; then
        echo "FAIL: multiple <close> variables were accepted: $decl" >&2
        exit 1
    fi
    if [[ "$ERR" != *"multiple to-be-closed variables"* ]]; then
        echo "FAIL: unexpected error for '$decl': $ERR" >&2
        exit 1
    fi
done

# A named vararg table (`...t`) is a read-only local: assigning it is rejected.
printf 'local function f(...t) t = {} end\n' > "$BUILD_DIR/attributes_vararg_ro.lua"
if ERR="$("$BIN" "$BUILD_DIR/attributes_vararg_ro.lua" -o "$BUILD_DIR/attributes_vararg_ro.wat" 2>&1)"; then
    echo "FAIL: assignment to a named vararg table was accepted" >&2
    exit 1
fi
if [[ "$ERR" != *"const variable"* ]]; then
    echo "FAIL: unexpected error for vararg table assignment: $ERR" >&2
    exit 1
fi
