-- The `%` operator is FLOOR modulo (a % b == a - floor(a/b)*b),
-- not truncating remainder. They differ when the operands have
-- different signs. (math.fmod is the truncating one.)

-- Integers.
print(7 % 3)         -- 1
print(-7 % 3)        -- 2     (was -1 with truncating)
print(7 % -3)        -- -2    (was 1)
print(-7 % -3)       -- -1
print(8 % 4)         -- 0
print(-8 % 4)        -- 0
print(0 % 5)         -- 0

-- Floats.
print(7.5 % 2.5)     -- 0.0
print(7.0 % 2.0)     -- 1.0
print(7.3 % 2.0)     -- 1.3
print(-7.3 % 2.0)    -- 0.7   (floor mod: result takes the sign of divisor)

-- Mixed int/float -> float.
print(1.0 % 1)       -- 0.0
print(5 % 2.0)       -- 1.0

-- Contrast with math.fmod (truncating):
print(math.fmod(-7, 3))   -- -1
print(-7 % 3)             -- 2
