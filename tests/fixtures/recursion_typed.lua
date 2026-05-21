-- Self-recursive local functions become typed direct-call targets under
-- LUA2WASM_OPT_INT (a `local function` captures itself as an upvalue). Behaviour
-- must match reference Lua with the flag on or off.

-- classic self-recursion, int param + int return
local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end
print(fib(10), fib(20))             -- 55	6765

-- accumulator recursion (two params)
local function sum(n, acc)
  if n == 0 then return acc end
  return sum(n - 1, acc + n)
end
print(sum(100, 0))                  -- 5050

-- factorial: grows but stays integer
local function fact(n)
  if n <= 1 then return 1 end
  return n * fact(n - 1)
end
print(fact(10))                     -- 3628800

-- float self-recursion
local function powhalf(x, k)
  if k == 0 then return x end
  return powhalf(x / 2, k - 1)
end
print(powhalf(1024.0, 4))           -- 64.0

-- recursion whose result feeds an unboxed caller loop
local function tri(n)
  if n == 0 then return 0 end
  return n + tri(n - 1)
end
local s = 0
for i = 1, 20 do s = s + tri(i) end
print(s)                            -- 1540

-- mutual recursion (cross-function upvalues): NOT specialized, must stay correct
local even, odd
function even(n) if n == 0 then return true else return odd(n - 1) end end
function odd(n) if n == 0 then return false else return even(n - 1) end end
print(even(10), odd(10))            -- true	false

-- a self-recursive function also used as a first-class value
local function dbl(n) if n <= 0 then return 0 end return 2 + dbl(n - 1) end
local fns = { dbl }
print(dbl(5), fns[1](5))            -- 10	10

-- recursion returning early with mixed shapes (boxed return)
local function pick(n)
  if n > 0 then return "pos" end
  return pick(n + 1)
end
print(pick(-3))                     -- pos
