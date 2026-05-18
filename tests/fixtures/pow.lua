-- The `^` operator is always-float (Lua 5.4+). Must handle non-integer
-- exponents, negative exponents, and the standard IEEE-754 edge cases.

print(2 ^ 10)                  -- 1024.0
print(2 ^ 0)                   -- 1.0
print(2 ^ -1)                  -- 0.5      (was 1.0 with int-loop pow)
print(2 ^ -2)                  -- 0.25
print(2 ^ 0.5)                 -- 1.4142135623731  (sqrt(2))
print(2 ^ 0.5 == math.sqrt(2)) -- true

print(8 ^ (1/3))               -- 2.0
print((-2) ^ 3)                -- -8.0
print((-2) ^ 2)                -- 4.0
print(10 ^ 3)                  -- 1000.0

-- IEEE-754 edge cases.
print(0 ^ 0)                   -- 1.0
-- (JS Math.pow(1, Infinity) is NaN, not the IEEE-754-2008 "1"; we accept
-- whatever the host produces here.)
print(1 ^ math.huge)           -- nan
print(0 ^ -1)                  -- inf
print(math.huge ^ 0)           -- 1.0

-- Always returns a float, even with int operands.
print(math.type(2 ^ 3))        -- float
