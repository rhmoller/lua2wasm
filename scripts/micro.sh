#!/usr/bin/env bash
# Run a microbenchmark (bench/micro/*.lua) under reference Lua and lua2wasm and
# print the two outputs side by side (see docs/perf-backlog.md, "Measuring").
#
#   scripts/micro.sh bench/micro/ops.lua
#   L2W_FLAGS=--loop-chunk=0 scripts/micro.sh bench/micro/strings_sections.lua
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:?usage: scripts/micro.sh FILE.lua}"
lua="${LUA_REF:-lua5.5}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2086  # L2W_FLAGS: extra compiler flags, word-split
"$root/build/lua2wasm" "$src" ${L2W_FLAGS:-} -o "$tmp/m.wasm"
"$lua" "$src" >"$tmp/ref.txt"
node --experimental-wasm-exnref "$root/runtime/host.mjs" "$tmp/m.wasm" >"$tmp/l2w.txt"
w=$(awk '{ if (length > m) m = length } END { print m + 2 }' "$tmp/ref.txt")
printf "%-${w}s| %s\n" "$lua" "lua2wasm"
awk -v w="$w" 'NR == FNR { ref[FNR] = $0; n = FNR; next }
               { printf "%-" w "s| %s\n", ref[FNR], $0; m = FNR }
               END { for (i = m + 1; i <= n; i++) printf "%-" w "s|\n", ref[i] }' "$tmp/ref.txt" "$tmp/l2w.txt"
