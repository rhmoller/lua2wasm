local list = {"apple", "banana", "cherry"}
for i, v in ipairs(list) do
  print(i)
  print(v)
end

local sum = 0
for i = 1, 100 do sum = sum + i end
print(sum)   -- 5050
