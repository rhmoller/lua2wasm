-- Table-library corners that already match reference Lua 5.5.
local t = { 1, 2, 3 } table.insert(t, 2, 99) print(table.concat(t, ",")) table.remove(t, 1) print(table.concat(t, ","))
local m = { 1, 2, 3, 4, 5 } table.move(m, 1, 3, 2) print(table.concat(m, ","))
local s = { 3, 1, 2 } table.sort(s, function(a, b) return a > b end) print(table.concat(s, ","))
local p = table.pack(1, nil, 3) print(p.n, p[1], p[3])
print(table.unpack({ 10, 20, 30, 40 }, 2, 3))
local h = { 1, 2, nil, 4 } local c = 0 for _ in ipairs(h) do c = c + 1 end print(c)
