-- Varargs: `...` in function declarations and as expression.

local function fwd(a, ...)
  print(a, ...)
end
fwd(1, 2, 3, 4)            -- 1\t2\t3\t4

local function all(...)
  return ...
end
print(all("a", "b", "c"))  -- a\tb\tc

local function first(...)
  local x = ...
  return x
end
print(first(7, 8, 9))      -- 7

-- `...` in a table constructor splices all values.
local function pack(...)
  return { ... }
end
local t = pack("p", "q", "r")
print(t[1], t[2], t[3], #t) -- p\tq\tr\t3

-- `...` in a call's argument list at the tail splices.
local function sum3(a, b, c)
  return a + b + c
end
local function via(...)
  return sum3(...)
end
print(via(10, 20, 30))     -- 60

-- select('#', ...) returns count; select(n, ...) skips first n-1.
local function n_of(...)
  return select('#', ...)
end
print(n_of())              -- 0
print(n_of(1, 2, 3, 4, 5)) -- 5

local function tail(...)
  return select(2, ...)
end
print(tail("x", "y", "z")) -- y\tz

-- No extras -> nil in single-value position.
local function g(a, ...)
  local x = ...
  return x
end
print(g(1))                -- nil
