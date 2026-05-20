-- Lua 5.4+: each iteration of a for-loop binds a FRESH control variable, so
-- closures created in different iterations capture distinct values. lua2wasm
-- used to share one mutated cell, yielding the final value everywhere.

-- numeric for
local fns = {}
for i = 1, 3 do fns[i] = function() return i end end
print(fns[1](), fns[2](), fns[3]())          -- 1 2 3

-- generic for (key and value both captured)
local kv = {}
for k, v in ipairs({"a", "b", "c"}) do
  kv[#kv + 1] = function() return k .. v end
end
print(kv[1](), kv[2](), kv[3]())             -- 1a 2b 3c

-- nested numeric loops, both control vars captured
local g = {}
for i = 1, 2 do
  for j = 1, 2 do g[#g + 1] = function() return i * 10 + j end end
end
print(g[1](), g[2](), g[3](), g[4]())        -- 11 12 21 22

-- generic-for non-first var reassigned in the body, then captured
local r = {}
for i, v in ipairs({5, 6, 7}) do
  v = v * 100
  r[i] = function() return v end
end
print(r[1](), r[2](), r[3]())                -- 500 600 700

-- break: closures from completed iterations keep their own values
local b = {}
for i = 1, 100 do
  b[i] = function() return i end
  if i == 3 then break end
end
print(b[1](), b[2](), b[3](), b[4])          -- 1 2 3 nil

-- a tight non-capturing loop still computes correctly (escape analysis
-- keeps it unboxed; this just guards the value)
local sum = 0
for i = 1, 100 do sum = sum + i end
print(sum)                                   -- 5050
