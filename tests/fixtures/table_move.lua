-- table.move(a1, f, e, t [, a2]) — copy a1[f..e] to (a2 or a1)[t..]

local function dump(t, n)
  local out = {}
  for i = 1, n do out[i] = tostring(t[i]) end
  print(table.concat(out, ","))
end

-- Basic in-place copy, non-overlapping.
local a = {10, 20, 30, 0, 0, 0}
table.move(a, 1, 3, 4)
dump(a, 6)                              -- 10,20,30,10,20,30

-- Copy to a different table.
local src = {1, 2, 3}
local dst = {nil, nil, nil, "tail"}
table.move(src, 1, 3, 1, dst)
dump(dst, 4)                            -- 1,2,3,tail

-- Overlap with t > f: must iterate backward to preserve source.
local b = {1, 2, 3, 4, 5}
table.move(b, 1, 4, 2)
dump(b, 5)                              -- 1,1,2,3,4

-- Overlap with t < f: forward iteration.
local c = {1, 2, 3, 4, 5}
table.move(c, 2, 5, 1)
dump(c, 5)                              -- 2,3,4,5,5

-- Empty range (f > e): no-op; the destination is returned.
local d = {1, 2, 3}
local r = table.move(d, 5, 4, 1)
print(rawequal(r, d))                   -- true

-- Returns the destination, not the source.
local s = {99}
local dst2 = {}
local r2 = table.move(s, 1, 1, 1, dst2)
print(rawequal(r2, dst2))               -- true
print(r2[1])                            -- 99

-- Moving nils across copies them (nil deletes the destination slot).
local e = {1, 2, 3}
local empty = {nil, nil, nil}
table.move(empty, 1, 3, 1, e)
print(e[1], e[2], e[3])                 -- nil   nil   nil
