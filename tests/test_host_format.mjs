// node --test pinning host-side number formatting.
import { test } from "node:test";
import assert from "node:assert/strict";
import { formatFloat, formatScalar } from "../runtime/format.mjs";

test("formatFloat: integer values get .0", () => {
    assert.equal(formatFloat(1.0), "1.0");
    assert.equal(formatFloat(-3.0), "-3.0");
    assert.equal(formatFloat(0.0), "0.0");
});

test("formatFloat: fractional values use Lua's %.14g", () => {
    assert.equal(formatFloat(1.5), "1.5");
    assert.equal(formatFloat(0.25), "0.25");
    assert.equal(formatFloat(1.0 / 3.0), "0.33333333333333");
});

test("formatFloat: non-finite", () => {
    assert.equal(formatFloat(Infinity), "inf");
    assert.equal(formatFloat(-Infinity), "-inf");
    assert.equal(formatFloat(NaN), "nan");
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

test("formatScalar: %g default maps to Lua's %.14g", () => {
    assert.equal(formatScalar(2, 0n, 1.5, -1), "1.5");
    assert.equal(formatScalar(2, 0n, 1.0 / 3.0, -1), "0.33333333333333");
});

test("formatScalar: tostring(float) matches formatFloat", () => {
    assert.equal(formatScalar(6, 0n, 1.0, 0), formatFloat(1.0));
    assert.equal(formatScalar(6, 0n, 1.5, 0), formatFloat(1.5));
    assert.equal(formatScalar(6, 0n, NaN, 0), "nan");
});
