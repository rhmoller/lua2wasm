-- Regression fixtures for multi-value assignment / declaration:
--   * a single-target assignment with a trailing call used to crash codegen
--   * the value list must evaluate strictly left-to-right
--   * excess values are still evaluated for their side effects

local function f() io.write("f ") return 1 end
local function g() io.write("g ") return 2 end
local function three() return 10, 20, 30 end

-- single-target plain-var assign, trailing call (was: compiler SIGSEGV)
A = 5, g()
print("A=" .. A)

-- single-target index assign, trailing call
local t = {}
t.x = 5, g()
print("t.x=" .. t.x)

-- local decl: value list evaluates left-to-right (f before g)
local p = f(), g()
print("p=" .. p)

-- local decl: excess non-call value is still evaluated (metamethod side effect)
local mt = setmetatable({}, { __index = function() io.write("idx ") return 9 end })
local q = 1, mt.foo
print("q=" .. q)

-- spread from a call fills several names (regression)
local x, y, z = three()
print("xyz", x, y, z)

-- multi-target assign spread (regression)
local a2, b2 = {}, {}
a2.v, b2.v = three()
print("ab", a2.v, b2.v)

-- global decl: value list evaluates left-to-right (f before g)
global gg = f(), g()
print("gg=" .. gg)
