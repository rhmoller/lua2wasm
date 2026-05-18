-- `//` is FLOOR division for both ints and floats. Differs from
-- truncating division (toward zero) when the operands have different
-- signs and there's a non-zero remainder.

-- Integers.
print(7 // 3)        -- 2
print(-7 // 3)       -- -3   (was -2 with truncating)
print(7 // -3)       -- -3   (was -2)
print(-7 // -3)      -- 2
print(8 // 4)        -- 2
print(-8 // 4)       -- -2   (exact: no correction needed)
print(9 // 4)        -- 2
print(-9 // 4)       -- -3
print(0 // 5)        -- 0

-- Floats.
print(7.5 // 2.5)    -- 3.0
print(-7.5 // 2.5)   -- -3.0
print(7.0 // 2.0)    -- 3.0
print(-7.3 // 2.0)   -- -4.0  (floor of -3.65)

-- Identity: (a // b) * b + (a % b) == a, for both ints and floats.
print((7 // 3) * 3 + (7 % 3))         -- 7
print((-7 // 3) * 3 + (-7 % 3))       -- -7
print((7 // -3) * -3 + (7 % -3))      -- 7
print((-7 // -3) * -3 + (-7 % -3))    -- -7

-- Mixed int/float -> float.
print(7 // 2.0)      -- 3.0
print(7.0 // 2)      -- 3.0
