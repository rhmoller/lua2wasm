-- Numeric for must terminate even when i+step overflows the integer range
-- (Lua 5.4 semantics). This used to loop forever (maxinteger+1 wraps to
-- mininteger, which is still <= the limit).
local c = 0
for i = math.maxinteger - 2, math.maxinteger do c = c + 1 end
print(c)
local d = 0
for i = math.mininteger + 2, math.mininteger, -1 do d = d + 1 end
print(d)
