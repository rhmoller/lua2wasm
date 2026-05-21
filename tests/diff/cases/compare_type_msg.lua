-- An order comparison between non-comparable operands must name the operand
-- types, like reference Lua: "attempt to compare two table values" when both
-- sides share a type, "attempt to compare table with number" otherwise.
-- We previously emitted a type-less "attempt to compare two values".
-- Semantic check (substring), not the file:line prefix.
local function cmp(f, want)
  local ok, err = pcall(f)
  print(ok, type(err) == "string" and err:find(want, 1, true) ~= nil)
end
cmp(function() return {} < {} end, "two table values")
cmp(function() return {} < 1 end, "table with number")
cmp(function() return 1 < "x" end, "number with string")
cmp(function() return {} <= {} end, "two table values")
cmp(function() return "a" < 2 end, "string with number")
