-- Light os shims: time, clock, date, getenv, exit.
-- The test runner sets LUA2WASM_TEST_ENV before invoking node, and a
-- fixed time is forced via LUA2WASM_TEST_TIME so date output is stable.

-- os.time returns an integer.
local t = os.time()
print(type(t), math.type(t))               -- number  integer

-- os.clock returns a non-negative float.
local c = os.clock()
print(type(c), math.type(c))               -- number  float
print(c >= 0)                              -- true

-- os.date with an explicit time we control.
local epoch = 1700000000  -- 2023-11-14 22:13:20 UTC
print(os.date("!%Y-%m-%d", epoch))          -- 2023-11-14
print(os.date("!%H:%M:%S", epoch))          -- 22:13:20
print(os.date("!%Y", epoch))                -- 2023
print(os.date("%%", epoch))                 -- %

-- os.date("*t", time) returns a table.
local d = os.date("!*t", epoch)
print(d.year, d.month, d.day)               -- 2023  11  14
print(d.hour, d.min, d.sec)                 -- 22  13  20
print(d.wday, d.yday)                       -- 3  318  (Tue, day 318 of year)
print(type(d.isdst))                        -- boolean

-- os.getenv: present and missing.
print(os.getenv("LUA2WASM_TEST_ENV"))       -- hello
print(os.getenv("LUA2WASM_NOT_SET_XYZ"))    -- nil

-- os.exit: tested by the test runner, separately.
print("done")
