-- Phase 6: error / pcall

local function divide(a, b)
  if b == 0 then error("div by zero") end
  return a / b
end

-- happy path
local ok, q = pcall(divide, 10, 2)
print(ok)         -- true
print(q)          -- 5.0

-- error path
local ok2, msg = pcall(divide, 1, 0)
print(ok2)        -- false
print(msg)        -- "div by zero"

-- pcall on a function that does not raise
local function add1(x) return x + 1 end
local ok3, r = pcall(add1, 41)
print(ok3)        -- true
print(r)          -- 42

-- nested pcall: inner error caught, outer continues
local ok4, outer_msg = pcall(function()
  local oki, ie = pcall(function() error("inner") end)
  if not oki then
    error("re-raised: " .. ie)
  end
end)
print(ok4)        -- false
print(outer_msg)  -- "re-raised: inner"

-- using pcall to return value with side-effect
global counter = 0
local function bumpy()
  counter = counter + 1
  if counter == 2 then error("two!") end
  return counter
end
local ok5, v1 = pcall(bumpy); print(ok5); print(v1)  -- true / 1
local ok6, v2 = pcall(bumpy); print(ok6); print(v2)  -- false / two!
local ok7, v3 = pcall(bumpy); print(ok7); print(v3)  -- true / 3
