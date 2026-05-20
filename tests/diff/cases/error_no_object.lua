-- error() / error(nil): the nil error object becomes the string
-- "<no error object>" in Lua 5.5 (luaG_errormsg). That message carries no
-- chunk name, so it is asserted verbatim here.
print(pcall(function() error() end))
print(pcall(function() error(nil) end))
local ok, e = pcall(function() error(nil) end)
print(ok, type(e), e)
-- An xpcall handler that returns nil likewise yields "<no error object>".
print(xpcall(function() error("x") end, function() return nil end))
-- ...but the handler still sees the original nil, not the substituted string.
print(xpcall(function() error(nil) end, function(h) return "h:" .. type(h) end))
