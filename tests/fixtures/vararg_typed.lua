-- Lua 5.5 typed-vararg parameter declaration: `function f(a, ...t)`.
-- Full semantics (binding `t` to the table-form of varargs) are not yet
-- implemented; for now we accept the syntax and `...` continues to work
-- as the regular vararg expression.
local function f(a, ...t)
  return a + select('#', ...)
end
print(f(10, "x", "y", "z"))   -- 10 + 3 = 13

local function g(...t)         -- no positional params
  return select('#', ...)
end
print(g(1, 2, 3, 4))           -- 4
