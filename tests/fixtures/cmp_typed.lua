-- Numeric comparison specialization (LUA2WASM_OPT_INT): same-type int/float
-- compares lower to iXX/fXX ops. Must match reference Lua with flag on or off.

-- all six operators, integer, as values
local a, b = 3, 7
print(a < b, a <= b, a > b, a >= b, a == b, a ~= b)   -- T T F F F T
print(b < a, b <= a, a == 3, a ~= 3)                   -- F F T F

-- in conditions (if / while / repeat)
local function sgn(x)
  if x < 0 then return -1 elseif x > 0 then return 1 else return 0 end
end
print(sgn(-9), sgn(0), sgn(9))                         -- -1 0 1

local i, acc = 0, 0
while i < 5 do acc = acc + i; i = i + 1 end
print(acc)                                             -- 10

local j = 0
repeat j = j + 1 until j >= 3
print(j)                                               -- 3

-- float comparisons
local x, y = 2.5, 2.5
print(x == y, x < 3.0, x > 3.0, x ~= 1.5)             -- T T F T
local fc = 0
for k = 1, 100 do if (k * 0.5) <= 10.0 then fc = fc + 1 end end
print(fc)                                              -- 20

-- NaN: every comparison with NaN is false except ~=
local nan = 0/0
print(nan == nan, nan ~= nan, nan < 1.0, nan > 1.0)   -- F T F F

-- int vs float equality (mixed -> generic path, must stay exact)
print(2 == 2.0, 2.0 == 2, 3 ~= 3.0)                    -- T T F

-- comparison result stored and reused
local big = (10 > 3)
print(big, type(big))                                  -- true boolean

-- comparison feeding boolean ops
print(1 < 2 and 3 < 4, 1 > 2 or 5 > 4)                -- T T
