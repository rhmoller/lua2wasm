-- Multiple assignment: every LHS table/key sub-expression and every RHS
-- value is evaluated before any store, and stores happen right-to-left (a
-- repeated target keeps its leftmost value) -- matching reference Lua.

-- The index variable is reassigned in the same statement: t[i] must use the
-- OLD i (captured before the store to i).
do
  local t = {10, 20, 30}
  local i = 1
  i, t[i] = i + 1, 99
  print(i, t[1], t[2], t[3])      -- 2 99 20 30
end

-- Repeated target: the leftmost value wins.
do
  local g = {}
  g.a, g.b, g.a = 1, 2, 3
  print(g.a, g.b)                 -- 1 2
end

-- Classic swaps still work.
do
  local a, b = 1, 2
  a, b = b, a
  print(a, b)                     -- 2 1
  local arr = {5, 6, 7}
  arr[1], arr[3] = arr[3], arr[1]
  print(arr[1], arr[2], arr[3])   -- 7 6 5
end

-- LHS table expressions are evaluated once each, left-to-right.
do
  local log = {}
  local function tab(name, t) log[#log + 1] = name; return t end
  local A, B = {}, {}
  tab("A", A)[1], tab("B", B).k = 10, 20
  print(A[1], B.k, table.concat(log, ","))   -- 10 20 A,B
end

-- A multi-value call on the RHS spreads across the index targets.
do
  local t = {}
  t[1], t[2], t[3] = (function() return 7, 8, 9 end)()
  print(t[1], t[2], t[3])         -- 7 8 9
end
