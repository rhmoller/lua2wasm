// Number formatting helpers shared between the host runtime and tests.
//
// `formatFloat(f)` mimics Lua 5.5's `tostring(<float>)`: it prints the shorter
// of %.14g / %.17g that round-trips back to the same double (Lua 5.5 widened
// the default beyond %.14g so floats survive a string round-trip), appends
// ".0" when the result looks like an integer, and renders non-finites as
// inf / -inf / nan.
//
// `cFormatG(x, prec, strip)` is a faithful C `printf("%.*g")`: exponent form
// when the decimal exponent is < -4 or >= prec, a >= 2-digit exponent, and
// trailing zeros stripped unless `strip` is false (the printf `#` flag).

export function cFormatG(x, prec, strip = true) {
    if (prec < 1) prec = 1;
    if (x === 0) {
        const body = Object.is(x, -0) ? "-0" : "0";
        return strip ? body : body + "." + "0".repeat(prec - 1);
    }
    // Canonical scientific form with `prec` significant digits handles all
    // rounding, including a carry that bumps the exponent (e.g. 9.99 -> 1e1).
    const m = /^(-?)(\d)(?:\.(\d+))?e([+-]\d+)$/.exec(x.toExponential(prec - 1));
    const sign = m[1];
    const digits = m[2] + (m[3] || "");          // exactly `prec` significant digits
    const exp = parseInt(m[4], 10);

    if (exp < -4 || exp >= prec) {               // exponent form
        let mant = m[2] + (m[3] ? "." + m[3] : "");
        if (strip) mant = mant.replace(/\.?0+$/, "");
        const e = (exp < 0 ? "-" : "+") + String(Math.abs(exp)).padStart(2, "0");
        return sign + mant + "e" + e;
    }

    let body;                                    // fixed form
    if (exp >= 0) {
        const intLen = exp + 1;
        body = digits.length <= intLen
            ? digits + "0".repeat(intLen - digits.length)
            : digits.slice(0, intLen) + "." + digits.slice(intLen);
    } else {
        body = "0." + "0".repeat(-exp - 1) + digits;
    }
    if (strip && body.indexOf(".") >= 0) body = body.replace(/\.?0+$/, "");
    return sign + body;
}

export function formatFloat(f) {
    if (Number.isNaN(f)) return "nan";
    if (f === Infinity) return "inf";
    if (f === -Infinity) return "-inf";
    // Lua 5.5: shorter of %.14g / %.17g that round-trips to the same double.
    let s = cFormatG(f, 14);
    if (Number(s) !== f) s = cFormatG(f, 17);
    if (/^-?[0-9]+$/.test(s)) s += ".0";         // integer-looking -> add ".0"
    return s;
}

// Format the (kind, i, f, prec) tuple emitted by the WAT formatter trampoline.
// Returns the string representation for one substitution.
//
// `kind` codes:
//   0 - %d (integer)         | uses i
//   2 - %g (general)         | uses f, prec; C printf %g (default precision 6).
//   3 - %f (fixed)           | uses f, prec; prec=-1 -> 6.
//   4 - %e (exponent)        | uses f, prec; prec=-1/6 -> 1 (Lua compat).
//   5 - %x (hex)             | uses i.
//   6 - tostring(float)      | uses f. Identical to formatFloat.
export function formatScalar(kind, i, f, prec) {
    if (prec < 0) prec = 6;
    switch (kind) {
        case 0: return String(i);
        case 2: return cFormatG(f, prec);
        case 3: return Number(f).toFixed(prec);
        case 4: return Number(f).toExponential(prec === 6 ? 1 : prec);
        case 5: return BigInt(i).toString(16);
        case 6: return formatFloat(f);
        default: return "";
    }
}
