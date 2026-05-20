-- math.atan(y [, x]) — 1-arg ordinary atan, 2-arg atan2.
-- math.log(x [, base]) — 1-arg natural log, 2-arg log_base.

-- atan: 1-arg
print(math.atan(1) * 4)            -- 3.1415926535898  (pi)
print(math.atan(0))                -- 0.0

-- atan: 2-arg (atan2 semantics — y first, then x)
print(math.atan(0, 1))             -- 0.0
print(math.atan(1, 0))             -- 1.5707963267949  (pi/2)
print(math.atan(-1, 0))            -- -1.5707963267949
print(math.atan(1, 1) * 4)         -- 3.1415926535898  (pi)
print(math.atan(0, -1))            -- 3.1415926535898  (pi)

-- log: 1-arg natural log
print(math.log(1))                 -- 0.0
print(math.log(math.exp(1)))       -- 1.0

-- log: 2-arg log_base
print(math.log(8, 2))              -- 3.0
print(math.log(100, 10))           -- 2.0
print(math.log(1, 5))              -- 0.0
print(math.log(1000, 10))          -- 3.0  (base 10 uses log10, like reference Lua)
