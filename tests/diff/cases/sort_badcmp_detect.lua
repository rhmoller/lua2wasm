-- table.sort raises "invalid order function for sorting" for a reflexive
-- (inconsistent) comparator — cmp(x,x) must be false. A valid order (incl. the
-- always-false "everything equal" comparator) is accepted. Code-review #9.
local function go(cmp)
  local ok, e = pcall(table.sort, { 5, 3, 8, 1, 9, 2, 7, 4, 6, 10, 11, 12 }, cmp)
  if ok then return "ok" end
  return tostring(e):match("invalid order") and "invalid-order" or "other"
end
print("return true ", go(function() return true end))
print("le          ", go(function(a, b) return a <= b end))
print("ge          ", go(function(a, b) return a >= b end))
print("return false", go(function() return false end))
print("normal lt   ", go(function(a, b) return a < b end))
print("default     ", select(1, pcall(table.sort, { 3, 1, 2 })) and "ok" or "err")
-- valid sorts still produce correct output
local t = { 5, 3, 8, 1, 9, 2 }; table.sort(t); print(table.concat(t, ","))
local u = { 5, 3, 8, 1, 9, 2 }; table.sort(u, function(a, b) return a > b end); print(table.concat(u, ","))
