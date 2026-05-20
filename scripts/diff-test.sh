#!/usr/bin/env bash
# Differential test harness: compare lua2wasm output against reference Lua 5.5.
#
# Each case is a self-contained .lua file under tests/diff/cases/. Its
# "expected" output is a golden file captured from reference Lua 5.5
# (tests/diff/expected/<case>.expected), so this harness does NOT need a
# `lua5.5` binary at run time -- only when regenerating goldens.
#
# tests/diff/manifest.tsv classifies each case:
#   pass  <name>  <description>   -- lua2wasm MUST match reference
#   xfail <name>  <description>   -- a captured bug: lua2wasm currently does
#                                    NOT match reference. When it starts
#                                    matching, the harness fails ("XPASS") so
#                                    you remember to promote it to `pass`.
#
# Usage:
#   scripts/diff-test.sh                      # check (repo defaults)
#   scripts/diff-test.sh BIN SRC_DIR BUILD    # check (CTest-style args)
#   scripts/diff-test.sh --regen              # rewrite goldens from lua5.5
#
# Exit status: 0 if every `pass` case matches and no `xfail` case has started
# matching; non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="check"
if [[ "${1:-}" == "--regen" ]]; then
    MODE="regen"; shift
fi

BIN="${1:-$ROOT/build/lua2wasm}"
SRC_DIR="${2:-$ROOT}"
BUILD_DIR="${3:-$ROOT/build}"

CASES_DIR="$SRC_DIR/tests/diff/cases"
EXPECTED_DIR="$SRC_DIR/tests/diff/expected"
MANIFEST="$SRC_DIR/tests/diff/manifest.tsv"
HOST="$SRC_DIR/runtime/host.mjs"
LUA_REF="${LUA_REF:-lua5.5}"

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }

# --- regen mode: capture reference output as golden files -------------------
if [[ "$MODE" == "regen" ]]; then
    if ! command -v "$LUA_REF" >/dev/null 2>&1; then
        echo "error: reference interpreter '$LUA_REF' not found (set LUA_REF)" >&2
        exit 2
    fi
    mkdir -p "$EXPECTED_DIR"
    n=0
    for lua in "$CASES_DIR"/*.lua; do
        base="$(basename "$lua" .lua)"
        # Run from the cases dir with a bare basename so any chunk-name in the
        # output (e.g. error positions) is portable across checkouts.
        out="$(cd "$CASES_DIR" && "$LUA_REF" "$base.lua" 2>&1)"
        printf '%s' "$out" > "$EXPECTED_DIR/$base.expected"
        n=$((n+1))
    done
    echo "regenerated $n golden(s) in $EXPECTED_DIR using $($LUA_REF -v 2>&1 | head -n1)"
    exit 0
fi

# --- check mode -------------------------------------------------------------
if [[ ! -x "$BIN" ]]; then
    echo "error: compiler not found at $BIN (build first)" >&2
    exit 2
fi

run_l2w() {
    local lua="$1" base="$2"
    local wat="$BUILD_DIR/diff_$base.wat" wasm="$BUILD_DIR/diff_$base.wasm"
    if ! "$BIN" "$lua" -o "$wat" >/dev/null 2>&1; then echo "<compile-fail>"; return; fi
    if ! wasm-as --all-features --disable-custom-descriptors -o "$wasm" "$wat" >/dev/null 2>&1; then
        echo "<assemble-fail>"; return
    fi
    node --experimental-wasm-exnref "$HOST" "$wasm" 2>&1
}

fail=0
n_pass_ok=0 n_pass_bad=0 n_xfail=0 n_xpass=0
declare -a details

while IFS=$'\t' read -r status name desc; do
    [[ -z "${status:-}" || "$status" == \#* ]] && continue
    lua="$CASES_DIR/$name.lua"
    golden="$EXPECTED_DIR/$name.expected"
    if [[ ! -f "$lua" ]]; then echo "error: missing case $lua" >&2; fail=1; continue; fi
    if [[ ! -f "$golden" ]]; then echo "error: missing golden $golden (run --regen)" >&2; fail=1; continue; fi

    exp="$(<"$golden")"
    got="$(run_l2w "$lua" "$name")"

    case "$status" in
      pass)
        if [[ "$got" == "$exp" ]]; then
            n_pass_ok=$((n_pass_ok+1))
            printf '  %s %-22s %s\n' "$(green PASS )" "$name" "$desc"
        else
            n_pass_bad=$((n_pass_bad+1)); fail=1
            printf '  %s %-22s %s\n' "$(red 'FAIL ')" "$name" "$desc"
            details+=("REGRESSION: $name"$'\n'"   ref: $exp"$'\n'"   got: $got")
        fi
        ;;
      xfail)
        if [[ "$got" != "$exp" ]]; then
            n_xfail=$((n_xfail+1))
            printf '  %s %-22s %s\n' "$(yellow xfail)" "$name" "$desc"
            details+=("xfail (captured bug): $name -- $desc"$'\n'"   ref: $exp"$'\n'"   got: $got")
        else
            n_xpass=$((n_xpass+1)); fail=1
            printf '  %s %-22s %s\n' "$(red XPASS)" "$name" "$desc"
            details+=("XPASS: $name now matches reference -- promote it to 'pass' in manifest.tsv"$'\n'"   out: $got")
        fi
        ;;
      *)
        echo "error: unknown status '$status' for $name" >&2; fail=1
        ;;
    esac
done < "$MANIFEST"

echo
echo "── details ──────────────────────────────────────────────"
for d in "${details[@]}"; do printf '%s\n\n' "$d"; done

echo "═════════════════════════════════════════════════════════"
printf 'pass: %d ok' "$n_pass_ok"
[[ $n_pass_bad -gt 0 ]] && printf ', %s' "$(red "$n_pass_bad REGRESSED")"
printf '   |   xfail: %d captured' "$n_xfail"
[[ $n_xpass -gt 0 ]] && printf ', %s' "$(red "$n_xpass XPASS (promote!)")"
echo
if [[ $fail -ne 0 ]]; then
    echo "$(red 'differential check FAILED') — see details above"
else
    echo "$(green 'differential check OK') — $n_xfail bug(s) still captured, no regressions"
fi
exit $fail
