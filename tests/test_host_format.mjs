// node --test pinning host-side number formatting.
import { test } from "node:test";
import assert from "node:assert/strict";
import { formatFloat, formatScalar, cFormatG } from "../runtime/format.mjs";

test("formatFloat: integer values get .0", () => {
    assert.equal(formatFloat(1.0), "1.0");
    assert.equal(formatFloat(-3.0), "-3.0");
    assert.equal(formatFloat(0.0), "0.0");
});

test("formatFloat: negative zero keeps its sign", () => {
    assert.equal(formatFloat(-0.0), "-0.0");
});

test("formatFloat: shortest round-trip (Lua 5.5)", () => {
    assert.equal(formatFloat(1.5), "1.5");
    assert.equal(formatFloat(0.25), "0.25");
    // %.14g doesn't round-trip these; Lua 5.5 falls through to %.17g.
    assert.equal(formatFloat(1.0 / 3.0), "0.33333333333333331");
    assert.equal(formatFloat(2 ** 0.5), "1.4142135623730951");
    assert.equal(formatFloat(0.1 + 0.2), "0.30000000000000004");
});

test("formatFloat: exponent-form floats are not given a spurious .0", () => {
    assert.equal(formatFloat(1e100), "1e+100");
    assert.equal(formatFloat(1e-100), "1e-100");
    assert.equal(formatFloat(1e15), "1e+15");
    // big integral-valued floats below the exponent threshold keep .0
    assert.equal(formatFloat(1234567890123456.0), "1234567890123456.0");
});

test("formatFloat: non-finite", () => {
    assert.equal(formatFloat(Infinity), "inf");
    assert.equal(formatFloat(-Infinity), "-inf");
    assert.equal(formatFloat(NaN), "nan");
});

test("cFormatG: C printf %g exponent threshold (exp < -4 or >= prec)", () => {
    assert.equal(cFormatG(1e-5, 6), "1e-05");   // exp -5 -> exponent form
    assert.equal(cFormatG(1e-4, 6), "0.0001");  // exp -4 -> fixed form
    assert.equal(cFormatG(1e6, 6), "1e+06");    // exp 6 >= prec 6 -> exponent
    assert.equal(cFormatG(100000, 6), "100000");
    assert.equal(cFormatG(1e20, 6), "1e+20");
    assert.equal(cFormatG(123456.789, 6), "123457");
});

test("formatScalar: %d uses i", () => {
    assert.equal(formatScalar(0, 42n, 0, -1), "42");
});

test("formatScalar: %x uses i in hex", () => {
    assert.equal(formatScalar(5, 255n, 0, -1), "ff");
});

test("formatScalar: %f default precision is 6", () => {
    assert.equal(formatScalar(3, 0n, 1.5, -1), "1.500000");
});

test("formatScalar: %f honors explicit precision", () => {
    assert.equal(formatScalar(3, 0n, 1.5, 2), "1.50");
});

test("formatScalar: %e default uses exponent precision 1", () => {
    assert.equal(formatScalar(4, 0n, 1234.0, -1), "1.2e+3");
});

test("formatScalar: %g is C printf %g (default precision 6)", () => {
    assert.equal(formatScalar(2, 0n, 1.5, -1), "1.5");
    assert.equal(formatScalar(2, 0n, 1.0 / 3.0, -1), "0.333333");
    assert.equal(formatScalar(2, 0n, 1e-5, -1), "1e-05");
});

test("formatScalar: tostring(float) matches formatFloat", () => {
    assert.equal(formatScalar(6, 0n, 1.0, 0), formatFloat(1.0));
    assert.equal(formatScalar(6, 0n, 1.5, 0), formatFloat(1.5));
    assert.equal(formatScalar(6, 0n, NaN, 0), "nan");
});
