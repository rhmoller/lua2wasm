-- Nested for-loops must not clobber each other's hidden control state.
-- Regression: numeric loops shared $for_stop/$for_step and generic loops
-- shared $for_iter_any/$for_state/$for_k at function scope, so an inner
-- loop corrupted the enclosing loop's bound/iterator.
local n = 0
for i = 1, 3 do for j = 1, 5 do n = n + 1 end end
print(n)                                   -- 15

local c = 0
for a = 1, 2 do for b = 1, 3 do for d = 1, 4 do c = c + 1 end end end
print(c)                                   -- 24

local t, u = {10, 20, 30}, {1, 2}
local sum, outer = 0, 0
for _, x in ipairs(t) do
  for _, y in ipairs(u) do sum = sum + x * y end
  outer = outer + 1
end
print(sum, outer)                          -- 180  3

-- mixed nesting and a triangular (inner bound depends on outer)
local tri = 0
for i = 1, 5 do for j = i, 5 do tri = tri + 1 end end
print(tri)                                 -- 15

-- pairs nested in numeric
local m = { a = 1, b = 2, c = 3 }
local g = 0
for i = 1, 3 do for k, v in pairs(m) do g = g + v end end
print(g)                                   -- 18
