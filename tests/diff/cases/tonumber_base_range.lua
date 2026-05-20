-- tonumber validates an explicit base is in [2, 36]; out of range is a
-- catchable error (it used to silently return nil). Valid conversions and
-- the no-base / nil-base paths are unchanged.
print(tonumber("ff", 16), tonumber("10", 2), tonumber("z", 36), tonumber("777", 8))
print(tonumber("zz", 36), tonumber("8", 8))    -- 1295  nil (invalid digit)
print(tonumber(42, nil), tonumber("0x1A"))     -- 42  26  (nil base = standard)
print(tonumber("  10  ", 10), tonumber("11", 2))

local function bad(...)
  local ok, e = pcall(tonumber, ...)
  return ok, tostring(e):find("base", 1, true) ~= nil
end
print(bad("7", 1))      -- false true  (base too small)
print(bad("7", 0))      -- false true
print(bad("7", 37))     -- false true  (base too big)
print(bad("7", -5))     -- false true
