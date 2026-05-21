-- tostring / string.format("%p") of a function must carry a per-object,
-- stable, distinct address suffix -- like reference Lua. Previously every
-- closure shared a constant address ("function: 0x0"), so two distinct
-- functions stringified identically. (Tables already worked.)
local f = function() end
local g = function() end
print(tostring(f):match("^function: ") ~= nil)              -- true
print(tostring(f) == tostring(f))                           -- true  (stable)
print(tostring(f) ~= tostring(g))                           -- true  (distinct)
print(string.format("%p", f) ~= string.format("%p", g))    -- true  (distinct)
print(string.format("%p", f) == string.format("%p", f))    -- true  (stable)
