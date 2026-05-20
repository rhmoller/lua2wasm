-- tostring(<float>) uses Lua 5.5's %.15g default (LUA_NUMBER_FMT, widened
-- from %.14g in 5.4), falling back to %.17g only when 15 significant digits
-- don't round-trip. The smallest subnormal needs the 15th digit.
print(5e-324)                 -- 4.94065645841247e-324  (15 sig figs)
print(1.5e-323)               -- 1.48219693752374e-323
print(1/3, 2/3, 1/7)          -- 17-digit forms (don't round-trip at 15)
print(0.1, 0.2, 0.3)          -- trimmed: 0.1  0.2  0.3
print(2 ^ 0.5, math.pi)       -- 1.4142135623730951  3.1415926535897931
print(123456789012345.6)      -- 123456789012345.59
print(1e16, 1e-5, 1e15)       -- 1e+16  1e-05  1e+15
print(100.0, 3.0, -0.0, 0.0)  -- 100.0  3.0  -0.0  0.0
print(0.30000000000000004)    -- 0.30000000000000004 (needs 17)
print(2 ^ 63, -2 ^ 63, 1 / 0, -1 / 0)  -- inf/-inf (NaN sign is platform-specific)
