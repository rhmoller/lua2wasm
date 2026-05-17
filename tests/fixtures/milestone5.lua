-- Phase 5: for loops, repeat/until, break, globals

-- numeric for
local sum = 0
for i = 1, 10 do
  sum = sum + i
end
print(sum)            -- 55

-- numeric for with step
for i = 10, 2, -2 do
  print(i)            -- 10 8 6 4 2
end

-- break
for i = 1, 100 do
  if i > 3 then break end
  print(i)            -- 1 2 3
end

-- repeat / until
local n = 0
repeat
  n = n + 1
until n >= 3
print(n)              -- 3

-- generic for with a hand-rolled iterator
local function range_iter(state, k)
  local nk = (k or 0) + 1
  if nk > state then return nil end
  return nk, nk * nk
end

for k, v in range_iter, 4, 0 do
  print(k)            -- 1, 2, 3, 4 (each on its own line)
  print(v)            -- 1, 4, 9, 16
end

-- generic for: just the key
for k in range_iter, 3 do
  print(k)            -- 1, 2, 3
end

-- globals
global counter
counter = 0
global bump
bump = function()
  counter = counter + 1
  return counter
end
print(bump())         -- 1
print(bump())         -- 2
print(counter)        -- 2

-- a closure that references a global
local function ref_global()
  return counter * 10
end
print(ref_global())   -- 20
