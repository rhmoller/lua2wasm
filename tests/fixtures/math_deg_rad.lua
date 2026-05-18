-- math.deg(x), math.rad(x) — radians <-> degrees.

print(math.deg(math.pi))          -- 180.0
print(math.deg(math.pi / 2))      -- 90.0
print(math.deg(0))                -- 0.0
print(math.deg(-math.pi))         -- -180.0

print(math.rad(180))              -- 3.1415926535898 (close to pi)
print(math.rad(90))               -- 1.5707963267949 (close to pi/2)
print(math.rad(0))                -- 0.0

-- Round-trip is stable within float precision.
local r = math.rad(math.deg(1.5))
print(r > 1.499 and r < 1.501)    -- true
