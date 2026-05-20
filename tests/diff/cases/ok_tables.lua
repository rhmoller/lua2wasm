-- Regression anchor: table library + iteration that already match reference.
local t = {}
for i = 1, 5 do t[i] = i * i end
print(#t, table.concat(t, ","))
table.insert(t, 3, 99); table.remove(t, 1)
print(table.concat(t, ","))
local s = 0
for k, v in pairs({ a = 1, b = 2, c = 3 }) do s = s + v end
print(s)
local sorted = { 5, 3, 8, 1, 9, 2 }; table.sort(sorted)
print(table.concat(sorted, ","))
