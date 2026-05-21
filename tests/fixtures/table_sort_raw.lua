-- table.sort must use *raw* table access: it must not consult __index
-- (for element reads) or __newindex (for swaps), exactly like reference Lua.
-- We attach a metatable whose __index would hand back a constant if it were
-- ever queried, and whose __newindex would divert writes; sort must ignore
-- both and operate directly on the stored array elements.
local t = {5, 3, 1, 4, 2}
local idx_hits = 0
local newidx_hits = 0
setmetatable(t, {
  __index = function(_, _) idx_hits = idx_hits + 1; return 0 end,
  __newindex = function(tab, k, v) newidx_hits = newidx_hits + 1; rawset(tab, k, v) end,
})

table.sort(t)
for i = 1, 5 do io.write(rawget(t, i), " ") end
print()

-- A custom comparator must likewise see the real stored values.
table.sort(t, function(a, b) return a > b end)
for i = 1, 5 do io.write(rawget(t, i), " ") end
print()

print("idx_hits", idx_hits)
print("newidx_hits", newidx_hits)
