#!/usr/bin/env bash
# Smoke-run the official Lua 5.5 test suite through lua2wasm.
# For each .lua file: compile -> assemble -> run, and record the outcome.
#
# Output: a markdown report on stdout.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/lua2wasm"
HOST="$ROOT/runtime/host.mjs"
TESTS_DIR="$ROOT/official-tests/lua-5.5.0-tests"
OUT_DIR="$(mktemp -d -t lua2wasm-smoke.XXXXXX)"

PER_FILE_TIMEOUT="${PER_FILE_TIMEOUT:-15}"

if [[ ! -x "$BIN" ]]; then
    echo "error: compiler not found at $BIN (build first)" >&2
    exit 2
fi

stages=()       # one of: compile, assemble, run, pass
files=()
firstlines=()

run_one() {
    local lua="$1"
    local base
    base="$(basename "$lua" .lua)"
    local wat="$OUT_DIR/$base.wat"
    local wasm="$OUT_DIR/$base.wasm"
    local log="$OUT_DIR/$base.log"

    : > "$log"

    if ! timeout "$PER_FILE_TIMEOUT" "$BIN" "$lua" -o "$wat" >"$log" 2>&1; then
        stages+=("compile"); files+=("$base"); firstlines+=("$(head -n1 "$log")")
        return
    fi
    if ! timeout "$PER_FILE_TIMEOUT" wasm-as --all-features -o "$wasm" "$wat" >"$log" 2>&1; then
        stages+=("assemble"); files+=("$base"); firstlines+=("$(head -n1 "$log")")
        return
    fi
    if ! timeout "$PER_FILE_TIMEOUT" node --experimental-wasm-exnref "$HOST" "$wasm" >"$log" 2>&1; then
        stages+=("run"); files+=("$base"); firstlines+=("$(tail -n1 "$log")")
        return
    fi
    stages+=("pass"); files+=("$base"); firstlines+=("")
}

# Skip all.lua (it's a driver that loads everything via dofile) and the
# library subdir for now — they need command-line args and host C libs we
# don't ship.
SKIP_RE='^(all)$'

mapfile -t LUAS < <(ls "$TESTS_DIR"/*.lua | sort)

for lua in "${LUAS[@]}"; do
    base="$(basename "$lua" .lua)"
    if [[ "$base" =~ $SKIP_RE ]]; then continue; fi
    run_one "$lua"
done

# Render report
n=${#files[@]}
pass=0 compile=0 assemble=0 run=0
for s in "${stages[@]}"; do
    case "$s" in
        pass) pass=$((pass+1));;
        compile) compile=$((compile+1));;
        assemble) assemble=$((assemble+1));;
        run) run=$((run+1));;
    esac
done

printf '# lua2wasm vs official Lua 5.5 test suite\n\n'
printf 'Total: **%d**  •  Pass: **%d**  •  Compile-fail: **%d**  •  Assemble-fail: **%d**  •  Run-fail: **%d**\n\n' \
    "$n" "$pass" "$compile" "$assemble" "$run"
printf 'Outputs kept in: `%s`\n\n' "$OUT_DIR"

printf '| File | Stage | First error line |\n'
printf '|------|-------|------------------|\n'
for i in "${!files[@]}"; do
    f="${files[$i]}"
    s="${stages[$i]}"
    e="${firstlines[$i]}"
    # Escape pipes for markdown
    e="${e//|/\\|}"
    # Truncate long lines
    if (( ${#e} > 140 )); then e="${e:0:137}..."; fi
    printf '| %s | %s | %s |\n' "$f" "$s" "$e"
done
