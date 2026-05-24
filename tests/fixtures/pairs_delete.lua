-- Deleting the current key during traversal is legal in Lua; next/pairs
-- must continue and terminate. Regression: next() raised "invalid key to
-- 'next'" for a key removed mid-traversal (it could no longer be located
-- after a compacting delete). Assertions avoid the unspecified hash order.

-- clear the whole table during a pairs() walk
local t = { a = 1, b = 2, c = 3, d = 4 }
local visited = 0
for k in pairs(t) do
  visited = visited + 1
  t[k] = nil
end
print("visited", visited)        -- 4 (each key seen exactly once)
print("after", next(t))          -- nil (table is empty)

-- delete only some keys during traversal; every key still visited once
local u = {}
for i = 1, 10 do u[i * 100] = i end   -- sparse integer keys -> hash part
local seen = 0
for k, v in pairs(u) do
  seen = seen + 1
  if v % 2 == 1 then u[k] = nil end   -- delete the odd-valued entries
end
print("seen", seen)              -- 10
local remain, sum = 0, 0
for _, v in pairs(u) do
  remain = remain + 1
  sum = sum + v
end
print("remain/sum", remain, sum) -- 5  30 (evens 2+4+6+8+10)

-- reuse the table after clearing it
local w = { x = 1, y = 2 }
for k in pairs(w) do w[k] = nil end
w.z = 99
local cnt = 0
for _ in pairs(w) do cnt = cnt + 1 end
print("reuse", cnt, w.z)         -- 1  99

-- resuming next() from a just-deleted key reaches the rest of the table
local m = { one = 1, two = 2, three = 3 }
local first = next(m)
m[first] = nil
local count = 1                   -- counts `first`
local key = first
repeat
  key = next(m, key)
  if key ~= nil then count = count + 1 end
until key == nil
print("resume", count)           -- 3 (deleted key + the two survivors)

-- a key that was never in the table still raises
local s = { p = 1 }
local ok, e = pcall(next, s, "absent")
print(ok, e:match("invalid key") ~= nil)  -- false  true
