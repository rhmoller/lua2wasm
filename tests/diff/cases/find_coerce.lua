-- string.find coerces numeric subject/pattern args to strings (like match/gsub
-- /gmatch), and a non-coercible arg raises catchably. Code-review finding #7.
local function bad(...) local ok, e = pcall(string.find, ...); return ok, type(e) end
print(string.find(12345, "23"))       -- 2 3
print(string.find("x97y", 97))        -- 2 3 (numeric pattern coerced)
print(string.find(12345, "9", 1, true)) -- 5 5 (plain find on numeric subject)
print(bad("x", {}))                   -- false string  (table pattern errors)
print(bad({}, "x"))                   -- false string  (table subject errors)
print(string.find("hello", "l"))      -- 3 3 (unchanged)
