-- string.gsub accepts a number replacement (coerced to its string form),
-- like reference Lua; non-string/number/table/function values still error.
local function err(...)
  local ok, e = pcall(string.gsub, ...)
  return ok, type(e) == "string"
end
print(string.gsub("abc", "a", 5))                       -- 5bc   1
print(string.gsub("a1b2", "%d", 0))                     -- a0b0  2
print(string.gsub("x", "x", 1.5))                       -- 1.5   1
print(string.gsub("hello", "l", 7))                     -- he77o 2
print(err("x", "x", true))                              -- false true
print(err("x", "x", nil))                               -- false true
-- existing function/table replacement forms still work
print(string.gsub("a1b2", "%d", function(d) return "[" .. d .. "]" end))
print(string.gsub("abc", "%a", { a = "X", b = "Y" }))
