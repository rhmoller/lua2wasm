-- Float rendering takes a fast native path when no decimal rounding tie is
-- possible and the exact ties-to-even path otherwise. Pin both: exact ties
-- (C rounds half to even, JS rounds half up), values just off a tie, the %g
-- fixed/exponent switch at 1e-4, %.15g/%.17g round-trip widening, and the
-- lowest-set-bit guard around 2^-27.
print(string.format("%.0f %.0f %.0f %.1f %.2f %.2e", 0.5, 1.5, 2.5, 0.25, 1.125, 1.125))
print(string.format("%.14g %.14g %.3g %.3g", 123456789012345, 123456789012355, 999.5, 1000.5))
print(string.format("%g %g %g %g %g", 0.0001, 0.00009999995, 1e-5, 123456, 1234567))
print(string.format("%.3f %.3f %.10f %.3e %.3e", 1/3, 2/3, 1/7, 1/3, 12345.6789))
print(1/3, 2/3, 1/7, 1e15/3, 1e16/3, 100/3, 0.1 + 0.2, 1e100/3, 1e-7/3)
print(2^-27, 2^-27 + 2^-60, 3 * 2^-28, 5 * 2^-27, 2^-26 + 2^-27)
print(string.format("%.20f %.25f", 0.1, 1/3))
print(string.format("%.2f %.2f %.4f", 1e21, -1e21, 12345678901234567890))
print(string.format("%#.0f %#.0e %#g %#g", 3, 3, 1.5, 100000))
print(string.format("%+.3f % .3f %08.3f %-8.3f|", 1/3, 1/3, -1/3, 1/3))
print(string.format("%.14g %.14g %.14g", 0.1, 1e100, 2^53))
print(string.format("%a %A %.3a", 1, 255.5, 1/3))
