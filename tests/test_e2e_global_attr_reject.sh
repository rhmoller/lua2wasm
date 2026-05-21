#!/usr/bin/env bash
# `global` attribute parsing must validate the attribute name against the same
# {const, close} set as `local` does. Previously the global path accepted any
# identifier (e.g. `global x <bogus>`), silently ignoring it; the local path
# rejected it. This guards the now-consistent rejection.
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"

# Sanity: a valid `<const>` global still compiles.
cat > "$BUILD_DIR/global_attr_ok.lua" <<'EOF'
global x <const> = 1
print(x)
EOF
if ! "$BIN" "$BUILD_DIR/global_attr_ok.lua" -o "$BUILD_DIR/global_attr_ok.wat" 2>/dev/null; then
    echo "FAIL: valid 'global x <const>' was rejected" >&2
    exit 1
fi

# An unknown attribute on a global must now be a compile-time error.
cat > "$BUILD_DIR/global_attr_bad.lua" <<'EOF'
global x <bogus> = 1
EOF
if "$BIN" "$BUILD_DIR/global_attr_bad.lua" -o "$BUILD_DIR/global_attr_bad.wat" 2>/dev/null; then
    echo "FAIL: 'global x <bogus>' was accepted" >&2
    exit 1
fi

# And `local` rejects it the same way (consistency check).
cat > "$BUILD_DIR/local_attr_bad.lua" <<'EOF'
local x <bogus> = 1
EOF
if "$BIN" "$BUILD_DIR/local_attr_bad.lua" -o "$BUILD_DIR/local_attr_bad.wat" 2>/dev/null; then
    echo "FAIL: 'local x <bogus>' was accepted" >&2
    exit 1
fi
