-- A NaN table key raises "table index is NaN" (Lua §3.4.4) on a write — it
-- cannot be stored. A read of an (absent) NaN key is fine and returns nil.
-- (Previously NaN was silently inserted but irrecoverable; now fixed.)
local function bad(f) local ok, e = pcall(f); return ok, type(e) end
local nan = 0.0 / 0.0
print(nan ~= nan)                                       -- true
print(bad(function() local t = {}; t[nan] = "x" end))  -- false  string
print(bad(function() return { [nan] = 1 } end))         -- false  string
local t = {}
print(t[nan])   -- nil (lookup of an absent NaN key is not an error)
print(t[1])     -- nil
