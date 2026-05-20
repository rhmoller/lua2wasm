-- Regression anchor: closures, varargs, multiple returns, pcall.
local function counter()
  local n = 0
  return function() n = n + 1; return n end
end
local f = counter()
print(f(), f(), f())

local function sum(...)
  local s = 0
  for _, v in ipairs({ ... }) do s = s + v end
  return s, select("#", ...)
end
print(sum(1, 2, 3, 4))
print(pcall(function() return 1, 2, 3 end))
