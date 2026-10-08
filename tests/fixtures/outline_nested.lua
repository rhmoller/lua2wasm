-- Run-once outlining beyond the main chunk's outermost loops
-- (src/codegen/outline.c): a numeric for directly inside an outlined loop
-- continues in a function of its own when it has more than a budget of
-- iterations left; functions handed to pcall / xpcall and a global function
-- defined and called once run once too. Inner loops here run 70000+ times
-- (past the default budget of 65536), so they take the resumed function.

local N = 70000

-- an inner loop with state from the outer one and the enclosing body
local total, rows = 0, {}
for r = 1, 3 do
  local row = 0
  for i = 1, N do row = row + (i % 7) * r end
  rows[r] = row
  total = total + row
end
print("nested", total, rows[1], rows[3])

-- negative step, a boxed bound, and an empty range
local down = 0
for r = 1, 2 do for i = N, 1, -1 do down = down + i % 3 end end
local fstop = N + 0.5
local fl = 0
for r = 1, 2 do for i = 1, fstop do fl = fl + 1 end end
local none = 0
for r = 1, 2 do for i = N, 1 do none = none + 1 end end
print("bounds", down, fl, none)

-- break and closures inside the long inner loop
local found, fns = nil, {}
for r = 1, 2 do
  for i = 1, N + r do
    if i == N + 1 then found = (found or 0) + i; break end
    if i % 30000 == 0 then fns[#fns + 1] = function() return r * i end end
  end
end
print("break", found, #fns, fns[1](), fns[#fns]())

-- a return from the inner loop of a run-once function's outer loop
local function search(target)
  for r = 1, 5 do
    for i = 1, N do
      if i * r == target then return r, i end
    end
  end
  return nil
end
print("return", search(3 * 69999))

-- functions handed to pcall / xpcall, with loops, results and errors
local ok, v = pcall(function()
  local s = 0
  for i = 1, N do s = s + i end
  return s
end)
print("pcall", ok, v)
local ok2, msg = pcall(function()
  for i = 1, N do if i == 5000 then error({code = i}) end end
end)
print("pcall error", ok2, type(msg), msg.code)
local function work() local s = 0 for i = 1, N do s = s + i % 3 end return s end
print("xpcall", xpcall(work, function(e) return "handled " .. tostring(e) end))
print("xpcall error", xpcall(function() for i = 1, N do if i == 3 then error("boom") end end end,
  function(e) return "handled" end))

-- a global main
function main()
  local acc = 0
  for i = 1, N do acc = acc + i % 11 end
  for r = 1, 2 do for i = 1, N do acc = acc - i % 11 end end
  return acc
end
print("main", main())

-- a to-be-closed variable around the loops
do
  local closed = 0
  local function run()
    local h <close> = setmetatable({}, {__close = function() closed = closed + 1 end})
    for r = 1, 2 do for i = 1, N do if i == N and r == 2 then return "done" end end end
  end
  print("close", run(), closed)
end
