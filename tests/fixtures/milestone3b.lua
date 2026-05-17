-- exercises phase 3b: multi-return, multi-assign, proper tail calls

-- multi-return from a function
local function pair()
  return 10, 20
end
local a, b = pair()
print(a)         -- 10
print(b)         -- 20

-- extra targets get nil
local x, y, z = pair()
print(z)         -- nil

-- multi-assign with non-call RHS
local p, q = 1, 2
p, q = q, p      -- swap by simultaneous evaluation
print(p)         -- 2
print(q)         -- 1

-- multi-assign with mixed RHS where last is a call
local m, n, o = 100, pair()
print(m)         -- 100
print(n)         -- 10
print(o)         -- 20

-- tail call: deep recursion that would overflow without TCO
local function countdown(n)
  if n == 0 then return "done" end
  return countdown(n - 1)
end
print(countdown(20000))  -- "done"

-- combination: tail call + closure capture
local function build_acc(start)
  local function go(n)
    if n == 0 then return start end
    start = start + 1
    return go(n - 1)
  end
  return go
end
local acc = build_acc(7)
print(acc(5))    -- 12  (7 + 5)
