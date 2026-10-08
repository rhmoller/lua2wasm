#!/usr/bin/env bash
# CPU profile of a Lua program compiled by lua2wasm, by wasm function
# (see docs/perf-backlog.md, "Measuring").
#
#   scripts/profile.sh bench/particles.lua          # top 25 functions by self time
#   scripts/profile.sh bench/particles.lua 40       # top 40
#   TREE=1 scripts/profile.sh bench/particles.lua   # plus the call tree
#   INLINING=ol_2 scripts/profile.sh bench/particles.lua
#                     # plus V8's inlining decisions while optimizing $ol_2
#   L2W_FLAGS=-O0 scripts/profile.sh ...            # extra compiler flags
#
# Function names need a wasm name section, which lua2wasm's own assembler
# doesn't write, so the WAT is assembled with Binaryen's `wasm-as -g` (and
# INLINING needs its `wasm-opt`). Samples every PROFILE_INTERVAL_US (default
# 100) microseconds; profiling slows the program, so read shares, not times.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:?usage: scripts/profile.sh FILE.lua [N]}"
n="${2:-25}"
command -v wasm-as >/dev/null || { echo "error: needs Binaryen's wasm-as (function names)" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2086  # L2W_FLAGS: extra compiler flags, word-split
"${L2W_BIN:-$root/build/lua2wasm}" "$src" ${L2W_FLAGS:-} -o "$tmp/prog.wat"
wasm-as --all-features -g "$tmp/prog.wat" -o "$tmp/prog.wasm"

node --experimental-wasm-exnref --cpu-prof --cpu-prof-interval "${PROFILE_INTERVAL_US:-100}" \
    --cpu-prof-dir="$tmp/prof" "$root/runtime/host.mjs" "$tmp/prog.wasm" >"$tmp/out.txt"
grep '^TIME ' "$tmp/out.txt" || true
node "$root/scripts/profile-report.mjs" top "$tmp"/prof/*.cpuprofile "$n" ${TREE:+--tree}

if [ -n "${INLINING:-}" ]; then
    echo
    echo "V8 inlining decisions in \$$INLINING:"
    wasm-opt --all-features --print-function-map "$tmp/prog.wasm" -o /dev/null >"$tmp/fmap.txt"
    node --experimental-wasm-exnref --trace-wasm-inlining "$root/runtime/host.mjs" "$tmp/prog.wasm" >"$tmp/trace.txt" 2>&1
    node "$root/scripts/profile-report.mjs" inlining "$tmp/fmap.txt" "$tmp/trace.txt" "$INLINING"
fi
