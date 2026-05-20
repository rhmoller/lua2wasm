-- tostring of a table/function uses Lua's "type: 0xADDR" format. The address
-- itself is implementation-defined (and nondeterministic in reference), so we
-- assert the shape, per-object stability, and distinctness — not the digits.
local t1, t2 = {}, {}
print(tostring(t1):match("^table: 0x%x+$") ~= nil)   -- true
print(tostring(t1) == tostring(t1))                  -- true  (stable per object)
print(tostring(t1) ~= tostring(t2))                  -- true  (distinct tables)

local function fn() end
print(tostring(fn):match("^function: 0x%x+$") ~= nil)        -- true
print(tostring(print):find("function:", 1, true) ~= nil)     -- true (C func form)

-- __tostring metamethod still wins over the address form.
local m = setmetatable({}, {__tostring = function() return "META" end})
print(tostring(m))                                   -- META

-- the format shows up wherever tostring is used (concat, print, %s).
print(("v=" .. tostring({})):match("v=table: 0x%x+$") ~= nil) -- true
print(string.format("%s", {}):match("^table: 0x%x+$") ~= nil) -- true
