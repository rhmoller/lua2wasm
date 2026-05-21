-- math.* functions must coerce numeric strings (like the arithmetic operators
-- already do) and raise a *catchable* "number expected" error on a
-- non-number, non-numeric-string argument -- not an uncatchable wasm trap.
-- Semantic check only (exact wording / chunk name not asserted).
print(math.floor("3"), math.ceil("2.5"), math.sqrt("4"), math.abs("-5"), math.fmod("7", "3"))
local function err_has(f, word)
  local ok, e = pcall(f)
  print(ok, type(e) == "string" and e:find(word, 1, true) ~= nil)
end
err_has(function() return math.floor({}) end, "number expected")
err_has(function() return math.sqrt("x") end, "number expected")
err_has(function() return math.abs(nil) end, "number expected")
err_has(function() return math.sin(true) end, "number expected")
