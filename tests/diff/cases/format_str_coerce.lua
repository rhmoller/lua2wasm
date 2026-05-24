-- string.format's numeric conversions coerce a numeric-string argument to a
-- number (like the arithmetic operators), and raise a catchable error on a
-- non-numeric / nil / wrong-type argument. The float path (%f %e %g ...) used
-- to silently format 0 for a string. Fuzzer-found.
print(string.format("%d", "42"))         -- 42
print(string.format("%.2f", "256.5"))    -- 256.50
print(string.format("%g", "1.5e3"))      -- 1500
print(string.format("%x", "255"))        -- ff
print(string.format("%5.2f", "3.14159")) --  3.14
print(string.format("%e", "100"))        -- 1.000000e+02
-- non-coercible arguments raise (semantic: pcall + type, wording not asserted)
local function bad(...) local ok, e = pcall(string.format, ...); return ok, type(e) end
print(bad("%d", "abc"))                   -- false string
print(bad("%f", "xyz"))                   -- false string
print(bad("%f", nil))                     -- false string
print(bad("%f", {}))                      -- false string
print(bad("%g", true))                    -- false string
