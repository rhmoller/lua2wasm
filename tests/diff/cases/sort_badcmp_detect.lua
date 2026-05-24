-- table.sort raises "invalid order function for sorting" for an inconsistent
-- comparator, matching reference Lua exactly — including its size-dependence
-- (small arrays use base cases without partitioning, so they are accepted).
-- A valid comparator (incl. one that errors on equal args) is unaffected except
-- where Lua itself self-compares (size 4). Code-review #9 (faithful auxsort port).
local function mk(n) local t = {} for i = 1, n do t[i] = n - i + 1 end return t end
local function det(n, cmp) return (pcall(table.sort, mk(n), cmp)) and "accept" or "reject" end
local rt, le, eq = "rt:", "le:", "eq:"
for n = 1, 8 do
  rt = rt .. " " .. det(n, function() return true end)
  le = le .. " " .. det(n, function(a, b) return a <= b end)
  eq = eq .. " " .. ((pcall(table.sort, mk(n), function(a, b) if a == b then error("EQ") end return a < b end)) and "ok" or "ERR")
end
print(rt); print(le); print(eq)
-- valid sorts still produce correct output
local s = mk(9); table.sort(s); print(table.concat(s, ","))
local d = mk(9); table.sort(d, function(a, b) return a > b end); print(table.concat(d, ","))
