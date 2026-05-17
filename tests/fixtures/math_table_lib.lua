-- math.ceil/min/max + table.insert/remove/concat
print(math.ceil(3.2))        -- 4
print(math.ceil(-1.5))       -- -1
print(math.ceil(5))          -- 5 (int passthrough)

print(math.min(7, 3, 5))     -- 3
print(math.max(7, 3, 5))     -- 7
print(math.min(2.5, 4))      -- 2.5
print(math.max(2, 5.5))      -- 5.5

local t = {}
table.insert(t, "a")
table.insert(t, "b")
table.insert(t, "c")
print(#t)                    -- 3
print(t[1])                  -- a
print(t[3])                  -- c

local removed = table.remove(t)
print(removed)               -- c
print(#t)                    -- 2

print(table.concat(t, ", "))      -- "a, b"
print(table.concat({"x","y","z"}, "-"))  -- "x-y-z"

-- table.insert with index
local u = {"a", "c"}
table.insert(u, 2, "b")
print(table.concat(u, ","))  -- "a,b,c"
