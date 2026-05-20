-- `global` is a contextual keyword in Lua 5.5: when it does not start a
-- declaration it is an ordinary identifier. Reference Lua accepts all of these.
global = 5
print(global)
global = { x = 10 }
global.x = global.x + 1
print(global.x)
print(type(global))
local t = { global = function() return "method" end }
print(t.global())
