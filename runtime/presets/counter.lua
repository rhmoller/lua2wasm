local function counter()
  local n = 0
  local function tick() n = n + 1; return n end
  return tick
end
local c = counter()
print(c())  -- 1
print(c())  -- 2
print(c())  -- 3
