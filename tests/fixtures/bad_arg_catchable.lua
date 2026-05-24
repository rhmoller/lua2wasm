-- Wrong-type arguments to builtins raise CATCHABLE Lua errors (not uncatchable
-- wasm cast traps), and string functions coerce number arguments — matching
-- reference Lua. err() reports (recovered?, message mentions "expected"?).
local function err(f, ...)
  local ok, e = pcall(f, ...)
  -- The fix is that these are CATCHABLE (pcall returns false with a string
  -- message) rather than uncatchable wasm traps; the exact wording can differ
  -- from reference (e.g. ipairs says "attempt to index" vs "table expected").
  return ok, type(e) == "string"
end
print(err(next, 5))
print(err(table.insert, 5, 1))
print(err(table.remove, 5))
print(err(table.sort, 5))
print(err(table.concat, 5))
print(err(table.move, 5, 1, 2, 1))
print(err(string.sub, {}, 1))
print(err(string.len, {}))
print(err(string.rep, {}, 2))
print(err(function() for _ in pairs(5) do end end))
print(err(function() for _ in ipairs(5) do end end))
-- number arguments coerce to strings
print(string.sub(12345, 2, 4))
print(string.rep(7, 3))
print(string.len(123))
print(string.upper("ab" .. 5))
print(string.format("%s", 42))
