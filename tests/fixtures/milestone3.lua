-- exercises phase 3a: local functions, recursion, closures with
-- mutable captures, function-returning-function

local function fact(n)
  if n <= 1 then return 1 end
  return n * fact(n - 1)
end
print(fact(6))   -- 720

local function counter()
  local n = 0
  local function tick()
    n = n + 1
    return n
  end
  return tick
end
local c = counter()
print(c())       -- 1
print(c())       -- 2
print(c())       -- 3

-- a fresh counter has its own n
local d = counter()
print(d())       -- 1
print(c())       -- 4

-- function-valued local + anonymous function expression
local add = function(a, b) return a + b end
print(add(10, 32))   -- 42

-- nested closures share the right boxes (transitive upvalue chain)
local function outer()
  local x = 100
  local function middle()
    local function inner()
      x = x + 1
      return x
    end
    return inner
  end
  return middle()
end
local inc = outer()
print(inc())     -- 101
print(inc())     -- 102
