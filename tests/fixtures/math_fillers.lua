-- math.fmod, math.modf, math.tointeger, math.type, math.ult,
-- math.maxinteger, math.mininteger.

-- math.fmod: truncating remainder (rounds quotient toward zero).
print(math.fmod(7, 3))            -- 1
print(math.fmod(-7, 3))           -- -1
print(math.fmod(7, -3))           -- 1
print(math.fmod(-7, -3))          -- -1
print(math.fmod(7.5, 2.5))        -- 0.0
print(math.fmod(7.0, 2.0))        -- 1.0
print(math.fmod(-7.5, 2.5))       -- -0.0 (fmod result takes the sign of the dividend)
local ok = pcall(function() return math.fmod(1, 0) end)
print(ok)                         -- false   (int / 0)

-- math.modf: (integral, fractional) where integral is int if it fits.
local i, f = math.modf(3.75)
print(i, f)                       -- 3   0.75
local i2, f2 = math.modf(-3.75)
print(i2, f2)                     -- -3   -0.75
print(math.modf(0))               -- 0   0.0
print(math.modf(5))               -- 5   0.0

-- math.tointeger: int passthrough, float-with-int-value, else nil.
print(math.tointeger(5))          -- 5
print(math.tointeger(5.0))        -- 5
print(math.tointeger(5.5))        -- nil
print(math.tointeger(nil))        -- nil
print(math.tointeger({}))         -- nil

-- math.type: "integer", "float", or nil for non-numbers.
print(math.type(5))               -- integer
print(math.type(5.0))             -- float
print(math.type("5"))             -- nil
print(math.type({}))              -- nil
print(math.type(nil))             -- nil

-- math.ult: unsigned i64 less-than.
print(math.ult(1, 2))             -- true
print(math.ult(2, 1))             -- false
print(math.ult(-1, 1))            -- false   (-1 as unsigned is 2^64-1)
print(math.ult(0, -1))            -- true    (0 < 2^64-1)

-- Constants.
print(math.maxinteger)            -- 9223372036854775807
print(math.mininteger)            -- -9223372036854775808
print(math.maxinteger + 1 == math.mininteger)  -- true (wrap)
