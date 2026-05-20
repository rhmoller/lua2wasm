-- BUG: %g (and default float printing) should switch to exponent form when the
-- exponent is < -4, like C printf. Reference: "1e-05" not "0.00001".
print(string.format("%g", 1e-5))
print(1e-5)
