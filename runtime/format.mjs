// Number formatting helpers shared between the host runtime and tests.
//
// `formatFloat(f)` mimics Lua 5.5's `tostring(<float>)`: it prints %.15g
// (LUA_NUMBER_FMT, widened from %.14g in 5.4) and falls back to %.17g
// (LUA_NUMBER_FMT_N) only when %.15g doesn't round-trip back to the same
// double, appends ".0" when the result looks like an integer, and renders
// non-finites as inf / -inf / nan.
//
// `cFormatG(x, prec, strip)` is a faithful C `printf("%.*g")`: exponent form
// when the decimal exponent is < -4 or >= prec, a >= 2-digit exponent, and
// trailing zeros stripped unless `strip` is false (the printf `#` flag).

// Exact decimal rounding of a double, ties-to-even — matching C printf's
// default rounding for %f/%e (FE_TONEAREST). JS toFixed/toExponential round
// ties away from zero, which diverges on exact halves (2.5 -> "3" vs C's "2").
// We decompose the double into its exact value (mantissa * 2^exp) and round
// with BigInt, so the result is exactly what glibc would print.

// Decompose a finite nonzero double into a positive BigInt mantissa `m` and
// an int exponent `e` with |x| == m * 2^e (exact).
function decomposeAbs(x) {
    const dv = new DataView(new ArrayBuffer(8));
    dv.setFloat64(0, x);
    const hi = dv.getUint32(0), lo = dv.getUint32(4);
    const expBits = (hi >>> 20) & 0x7ff;
    let m = (BigInt(hi & 0xfffff) << 32n) | BigInt(lo >>> 0);
    let e;
    if (expBits === 0) {
        e = -1074; // subnormal: no implicit leading bit
    } else {
        m |= 1n << 52n; // normal: restore the implicit leading 1
        e = expBits - 1075;
    }
    return { m, e };
}

// Exact test: is m*2^e >= 10^k ? (clears negative exponents into the other
// side so both operands are BigInts). Used to pin floor(log10|x|) exactly.
function geqPow10(m, e, k) {
    let a = m, b = 1n;
    if (e >= 0) a <<= BigInt(e); else b <<= BigInt(-e);
    if (k >= 0) b *= 10n ** BigInt(k); else a *= 10n ** BigInt(-k);
    return a >= b;
}

// round(|x| * 10^k) to the nearest integer, ties-to-even, as a BigInt.
function scaledRoundEven(m, e, k) {
    let num = m, den = 1n;
    if (k >= 0) num *= 10n ** BigInt(k);
    else den *= 10n ** BigInt(-k);
    if (e >= 0) num <<= BigInt(e);
    else den <<= BigInt(-e);
    const q = num / den, r = num % den, twice = 2n * r;
    if (twice < den) return q;
    if (twice > den) return q + 1n;
    return q % 2n === 0n ? q : q + 1n; // exact tie -> round to even
}

// C printf "%.<prec>f", ties-to-even. Returns the body (with leading "-").
export function cFormatF(x, prec) {
    const sign = x < 0 || Object.is(x, -0) ? "-" : "";
    if (x === 0) return sign + (prec > 0 ? "0." + "0".repeat(prec) : "0");
    const { m, e } = decomposeAbs(x);
    let s = scaledRoundEven(m, e, prec).toString();
    if (prec === 0) return sign + s;
    if (s.length <= prec) s = "0".repeat(prec - s.length + 1) + s;
    return sign + s.slice(0, s.length - prec) + "." + s.slice(s.length - prec);
}

// C printf "%.<prec>e", ties-to-even. Returns the body (with leading "-").
export function cFormatE(x, prec) {
    const sign = x < 0 || Object.is(x, -0) ? "-" : "";
    const expStr = (E) => "e" + (E < 0 ? "-" : "+") + String(Math.abs(E)).padStart(2, "0");
    if (x === 0) return sign + (prec > 0 ? "0." + "0".repeat(prec) : "0") + expStr(0);
    const { m, e } = decomposeAbs(x);
    const hi = 10n ** BigInt(prec + 1);
    // Pin E = floor(log10|x|) exactly (Math.log10 is imprecise near powers of
    // ten, which otherwise picks the wrong rounding grid).
    let E = Math.floor(Math.log10(Math.abs(x)));
    while (geqPow10(m, e, E + 1)) E++;
    while (!geqPow10(m, e, E)) E--;
    // Round to prec+1 significant digits; a rounding carry can still push one
    // extra digit (e.g. 9.99 -> 1.00e1).
    let N = scaledRoundEven(m, e, prec - E);
    if (N >= hi) { N /= 10n; E++; }
    const s = N.toString();
    const mant = prec > 0 ? s[0] + "." + s.slice(1) : s;
    return sign + mant + expStr(E);
}

export function cFormatG(x, prec, strip = true) {
    if (prec < 1) prec = 1;
    if (x === 0) {
        const body = Object.is(x, -0) ? "-0" : "0";
        return strip ? body : body + "." + "0".repeat(prec - 1);
    }
    // Canonical scientific form with `prec` significant digits handles all
    // rounding, including a carry that bumps the exponent (e.g. 9.99 -> 1e1).
    // cFormatE rounds ties-to-even (C printf), unlike JS toExponential.
    const m = /^(-?)(\d)(?:\.(\d+))?e([+-]\d+)$/.exec(cFormatE(x, prec - 1));
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
    // Lua 5.5: %.15g (LUA_NUMBER_FMT), widening to %.17g only when %.15g
    // doesn't round-trip back to the same double.
    let s = cFormatG(f, 15);
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
