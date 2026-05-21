-- Deep *non-tail* recursion must raise a *catchable* "stack overflow" the way
-- reference Lua does, instead of an uncatchable host-stack trap that pcall
-- cannot intercept. Semantic check only (the exact depth and chunk name vary).
local function f(n)
  if n == 0 then return 0 end
  return 1 + f(n - 1)
end
local ok, err = pcall(f, 1000000)
print(ok, type(err) == "string" and err:find("stack overflow", 1, true) ~= nil)
-- Shallow recursion still works and pcall still returns the value.
print(pcall(f, 10))
