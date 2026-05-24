-- A non-function comparator to table.sort is a CATCHABLE error (was an
-- uncatchable "illegal cast" wasm trap); nil/absent uses the default order.
local function err(...)
  local ok, e = pcall(table.sort, ...)
  return ok, type(e) == "string" and e:match("function") ~= nil
end
print(err({3, 1, 2}, "x"))     -- false  true
print(err({3, 1, 2}, 5))       -- false  true
print(err({3, 1, 2}, {}))      -- false  true

local a = {3, 1, 2}
table.sort(a)                  -- default order
print(a[1], a[2], a[3])        -- 1 2 3
local b = {3, 1, 2}
table.sort(b, nil)             -- explicit nil cmp == default
print(b[1], b[2], b[3])        -- 1 2 3
local c = {3, 1, 2}
table.sort(c, function(x, y) return x > y end)
print(c[1], c[2], c[3])        -- 3 2 1
