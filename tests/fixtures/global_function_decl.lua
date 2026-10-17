-- Lua 5.5 combined form: `global function f(...) ... end` is equivalent to
-- `global f; global f = function(...) ... end`, and declares f before its body.
global print
global function greet(name) return name and "hello " .. name or greet("world") end
print(greet("world"))
