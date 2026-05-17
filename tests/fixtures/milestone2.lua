-- exercises v2 surface: locals, strings, floats, comparisons,
-- if/elseif/else, while, and/or/not, concat
local i = 0
local sum = 0
while i < 5 do
  i = i + 1
  sum = sum + i
end
print(sum)             -- 15
print("hi " .. "there") -- "hi there"
print(3 / 2)           -- 1.5
print(7 // 2)          -- 3
print(1 == 1.0)        -- true
print(not false)       -- true
print(nil or "default") -- "default"
print(1 and 2)         -- 2
if sum > 10 then
  print("big")
elseif sum == 10 then
  print("ten")
else
  print("small")
end
local s = "abc"
print(#s)              -- 3
