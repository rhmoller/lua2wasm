-- A local function the main chunk calls exactly once, outside any loop, runs
-- its outermost loops in resumable functions like the main chunk's own loops
-- (src/codegen/outline.c). Returns from inside those loops come back through
-- every kind of entry; functions called more than once, recursively or
-- through a closure are left alone. Every case must behave as plain loops.

-- fannkuch-style: tables, a return of two values from deep inside the loop
local function search(n)
  local seen, hits, best = {}, 0, 0
  for i = 1, n do seen[i] = (i * 7) % n end
  repeat
    hits = hits + 1
    for i = 1, n do
      if seen[i] == hits % n then best = best + i end
      if hits > 50 then return hits, best end
    end
  until false
end
local hits, best = search(40)
print("search", hits, best)

-- a single integer result from inside a loop (a typed single-result entry)
local function first_square_over(limit)
  for i = 1, limit do
    if i * i > limit then return i end
  end
  return -1
end
print("square", first_square_over(5000))

-- a float result, and falling off the end of the loop
local function harmonic(n)
  local s = 0.0
  for i = 1, n do s = s + 1 / i end
  return s
end
print("harmonic", string.format("%.6f", harmonic(100000)))

-- upvalues: main-chunk locals read and written from the function's loops
local total, factor = 0, 3
local function accumulate(n)
  for i = 1, n do total = total + i * factor end
  local k = 0
  while k < 5 do k = k + 1; factor = factor + 1 end
end
accumulate(100)
print("upvalues", total, factor)

-- varargs inside the loop
local function sum_args(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + (select(i, ...)) end
  for _, v in ipairs({...}) do s = s + v end
  return s
end
print("varargs", sum_args(1, 2, 3, 4))

-- a call with extra arguments (not a direct call)
local function count_to(n)
  local c = 0
  while c < n do c = c + 1 end
  return c
end
print("extra args", count_to(1000, "ignored"))

-- a <close> value open when the loop returns
local log = {}
local function closing(n)
  local guard <close> = setmetatable({}, {__close = function() log[#log + 1] = "guard" end})
  for i = 1, n do
    local c <close> = setmetatable({}, {__close = function() log[#log + 1] = "c" .. i end})
    if i == 3 then return "returned at " .. i end
  end
end
print("close", closing(10), table.concat(log, " "))

-- a long loop in a run-once function crosses suspensions at the default budget
local function long_run()
  local acc = 0
  for i = 1, 400000 do acc = (acc + i * 31) % 1000003 end
  return acc
end
print("long", long_run())

-- not run once: called twice, recursive, or reachable through a closure
local function twice(n) local s = 0 for i = 1, n do s = s + i end return s end
local function fact(n) if n <= 1 then return 1 end local r = 1 for i = 2, n do r = r * i end return r * 0 + fact(n - 1) * n end
local function via_closure(n) local s = 0 for i = 1, n do s = s + 2 end return s end
local call = function(x) return via_closure(x) end
print("others", twice(10), twice(20), fact(6), call(7), call(8))
