// Number formatting helpers shared between the host runtime and tests.
//
// `formatFloat(f)` mimics Lua's `tostring(<float>)`: integers render as
// "N.0", non-finites as inf/-inf/nan, and the default precision matches
// Lua's `LUAI_NUMFFORMAT` ("%.14g").

export function formatFloat(f) {
    if (!Number.isFinite(f)) {
        return f === Infinity ? "inf" : f === -Infinity ? "-inf" : "nan";
    }
    if (Number.isInteger(f)) return `${f}.0`;
    return Number(f).toPrecision(14).replace(/\.?0+(e|$)/, "$1");
}

// Format the (kind, i, f, prec) tuple emitted by the WAT formatter trampoline.
// Returns the string representation for one substitution.
//
// `kind` codes:
//   0 - %d (integer)         | uses i
//   2 - %g (general)         | uses f, prec; prec=-1/6 maps to Lua's %.14g.
//   3 - %f (fixed)           | uses f, prec; prec=-1 -> 6.
//   4 - %e (exponent)        | uses f, prec; prec=-1/6 -> 1 (Lua compat).
//   5 - %x (hex)             | uses i.
//   6 - tostring(float)      | uses f. Identical to formatFloat.
export function formatScalar(kind, i, f, prec) {
    if (prec < 0) prec = 6;
    switch (kind) {
        case 0: return String(i);
        case 2: return Number(f).toPrecision(prec === 6 ? 14 : prec).replace(/\.?0+(e|$)/, "$1");
        case 3: return Number(f).toFixed(prec);
        case 4: return Number(f).toExponential(prec === 6 ? 1 : prec);
        case 5: return BigInt(i).toString(16);
        case 6: return formatFloat(f);
        default: return "";
    }
}
