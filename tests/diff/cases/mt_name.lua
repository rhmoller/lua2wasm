-- A metatable's __name field renames the object's default type in tostring
-- ("Point: 0x...") and in type-aware error messages ("attempt to compare two
-- Point values"). We previously ignored __name entirely.
local mt = {__name = "Point"}
local p = setmetatable({}, mt)
local q = setmetatable({}, mt)
print(tostring(p):match("^Point: ") ~= nil)                -- true
local ok, err = pcall(function() return p < q end)
print(ok, type(err) == "string" and err:find("two Point values", 1, true) ~= nil)
-- A table without __name still says "table".
local plain = {}
print(tostring(plain):match("^table: ") ~= nil)            -- true
