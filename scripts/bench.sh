#!/usr/bin/env bash
# Run the bench/ programs under reference lua5.5, luajit (when installed) and
# lua2wasm, and print a table of wall-clock times reported by each program's
# own `TIME` line (os.clock, so process startup is excluded).
#
#   scripts/bench.sh                 # every bench/*.lua
#   scripts/bench.sh nbody oo        # a subset, by basename
#   RUNS=3 scripts/bench.sh          # repeat each run, keep the fastest
#   L2W_FLAGS=-O0 scripts/bench.sh   # extra lua2wasm flags (boxed fallback)
#
# Every program prints its result before the TIME line; the lua2wasm output is
# diffed against lua5.5's, and a mismatch is reported in the last column.
# Extra timing lines a program prints as TIME_<name> are left out of the diff.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
l2w=${LUA2WASM:-$root/build/lua2wasm}
host=$root/runtime/host.mjs
runs=${RUNS:-1}
lua=$(command -v lua5.5 || true)
jit=$(command -v luajit || true)

[ -x "$l2w" ] || { echo "error: $l2w not built (cmake --build build)" >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

if [ $# -gt 0 ]; then
    benches=("$@")
else
    benches=()
    for f in "$root"/bench/*.lua; do benches+=("$(basename "$f" .lua)"); done
fi

# best_time CMD... -> prints the smallest TIME over $runs runs; the first run's
# full output (minus TIME / TIME_* lines) goes to $tmp/last.out for the
# correctness diff.
best_time() {
    local best="" t
    for ((i = 0; i < runs; i++)); do
        if ! "$@" >"$tmp/run.out" 2>&1; then echo "FAIL"; return; fi
        t=$(grep '^TIME ' "$tmp/run.out" | awk '{print $2}')
        [ -n "$t" ] || { echo "NOTIME"; return; }
        if [ -z "$best" ] || awk "BEGIN{exit !($t < $best)}"; then best=$t; fi
        [ $i -eq 0 ] && grep -Ev '^TIME[ _]' "$tmp/run.out" >"$tmp/last.out"
    done
    echo "$best"
}

ratio() { # ratio A B -> B/A formatted, or "-" when either is not a number
    if [[ $1 =~ ^[0-9.]+$ && $2 =~ ^[0-9.]+$ ]]; then
        awk "BEGIN{printf \"%.2fx\", $2 / $1}"
    else echo "-"; fi
}

printf '%-14s %9s %9s %10s %9s  %s\n' bench lua5.5 luajit lua2wasm ratio output
for b in "${benches[@]}"; do
    src=$root/bench/$b.lua
    [ -f "$src" ] || { echo "no such bench: $b" >&2; continue; }
    ref="-"; jt="-"; same="-"
    if [ -n "$lua" ]; then
        ref=$(best_time "$lua" "$src"); cp "$tmp/last.out" "$tmp/ref.out" 2>/dev/null || true
    fi
    [ -n "$jit" ] && jt=$(best_time "$jit" "$src")
    # shellcheck disable=SC2086
    if "$l2w" "$src" ${L2W_FLAGS:-} -o "$tmp/$b.wasm" 2>"$tmp/cerr"; then
        w=$(best_time node --experimental-wasm-exnref "$host" "$tmp/$b.wasm")
        if [ -n "$lua" ] && [ -f "$tmp/ref.out" ]; then
            if diff -q "$tmp/ref.out" "$tmp/last.out" >/dev/null; then same=ok; else same=DIFF; fi
        fi
    else
        w=COMPILEFAIL
    fi
    printf '%-14s %9s %9s %10s %9s  %s\n' "$b" "$ref" "$jt" "$w" "$(ratio "$ref" "$w")" "$same"
done
