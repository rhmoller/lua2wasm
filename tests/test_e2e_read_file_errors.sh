#!/usr/bin/env bash
# read_file hardening: opening a directory must fail loudly instead of
# "succeeding" via fopen("rb") and then misbehaving on fseek/fread.
# Also covers a missing input file (fopen failure).
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
WAT="$BUILD_DIR/read_file_errors.wat"

# 1. A directory as the main input -> non-zero exit, diagnostic mentions
#    the path. Must NOT produce a WAT file.
rm -f "$WAT"
if "$BIN" "$BUILD_DIR" -o "$WAT" 2>/tmp/rfe_dir.err; then
    echo "FAIL: compiling a directory unexpectedly succeeded" >&2
    exit 1
fi
if [[ -f "$WAT" ]]; then
    echo "FAIL: a WAT file was produced for a directory input" >&2
    exit 1
fi
if ! grep -q "not a regular file" /tmp/rfe_dir.err; then
    echo "FAIL: directory error message missing 'not a regular file'" >&2
    cat /tmp/rfe_dir.err >&2
    exit 1
fi

# 2. A directory passed as a -m module also fails loudly.
ENTRY="$BUILD_DIR/read_file_errors_entry.lua"
printf 'print("unused")\n' > "$ENTRY"
if "$BIN" "$ENTRY" -m "$BUILD_DIR" -o "$WAT" 2>/tmp/rfe_mod.err; then
    echo "FAIL: a directory -m module unexpectedly succeeded" >&2
    exit 1
fi
if ! grep -q "not a regular file" /tmp/rfe_mod.err; then
    echo "FAIL: module directory error message missing 'not a regular file'" >&2
    cat /tmp/rfe_mod.err >&2
    exit 1
fi

# 3. A missing input file fails (fopen perror), non-zero exit.
if "$BIN" "$BUILD_DIR/definitely_missing.lua" -o "$WAT" 2>/dev/null; then
    echo "FAIL: a missing input file unexpectedly succeeded" >&2
    exit 1
fi

echo "ok: read_file rejects directories and missing files"
