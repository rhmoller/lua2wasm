-- Lua 5.5 combined form: `global function f(...) ... end` is equivalent
-- to `global f; f = function(...) ... end`.
global function greet(name) return "hello " .. name end
print(greet("world"))
