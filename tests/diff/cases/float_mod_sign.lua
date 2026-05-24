-- Float `%` (floor-modulo): the result's sign follows the divisor for nonzero
-- results, and an exact-zero result takes the sign of the *dividend* (so
-- 8 % -8 is 0.0 but -8 % 8 is -0.0). The old `a - floor(a/b)*b` gave +0.0 for
-- every exact division (x - x = +0). Fuzzer-found via (0.0 + -maxint) % -8.
print(8.0 % -8.0)    -- 0.0
print(-8.0 % 8.0)    -- -0.0
print(-8.0 % -8.0)   -- -0.0
print(7.5 % -2.5)    -- 0.0
print(-7.5 % 2.5)    -- -0.0
print(-5.5 % 2.0)    -- 0.5
print(5.5 % -2.0)    -- -0.5
print(5.5 % 2.0)     -- 1.5
print((0.0 + -9223372036854775807) % -8)  -- -0.0
