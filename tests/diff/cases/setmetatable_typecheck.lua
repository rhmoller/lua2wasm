-- setmetatable rejects a non-table first argument, and a metatable that is
-- neither nil nor a table, with a *catchable* error. Both were illegal-cast
-- wasm traps before. Semantic check only (wording/chunk name not asserted).
local function bad(...)
  local ok, err = pcall(setmetatable, ...)
  return ok, type(err), tostring(err):find("table") ~= nil
end
print(bad("x", {}))     -- false string true
print(bad(5, {}))       -- false string true
print(bad(nil, {}))     -- false string true
print(bad({}, 5))       -- false string true
print(bad({}, "y"))     -- false string true

-- Valid uses are unchanged.
local t = setmetatable({}, {__index = {x = 42}})
print(t.x)                          -- 42
print(setmetatable(t, nil) == t)    -- true  (returns the table; nil clears mt)
print(getmetatable(t))              -- nil   (metatable cleared)
