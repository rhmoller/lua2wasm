-- table.sort(t [, cmp]) — in-place sort of t[1..#t].
-- Default order is the < operator; cmp(a, b) -> true means a should
-- precede b.

local function show(t)
  print(table.concat(t, ","))
end

-- Default (ascending) sort over integers.
local t = {3, 1, 4, 1, 5, 9, 2, 6, 5, 3}
table.sort(t)
show(t)                                    -- 1,1,2,3,3,4,5,5,6,9

-- Descending via comparator.
local d = {3, 1, 4, 1, 5, 9, 2, 6, 5, 3}
table.sort(d, function(a, b) return a > b end)
show(d)                                    -- 9,6,5,5,4,3,3,2,1,1

-- Strings (lexicographic).
local s = {"banana", "apple", "cherry"}
table.sort(s)
show(s)                                    -- apple,banana,cherry

-- Custom key (sort by length).
local words = {"abc", "z", "ab", "abcd"}
table.sort(words, function(a, b) return #a < #b end)
show(words)                                -- z,ab,abc,abcd

-- Already-sorted input is stable in shape.
local a = {1, 2, 3, 4, 5}
table.sort(a)
show(a)                                    -- 1,2,3,4,5

-- Reverse-sorted input.
local r = {5, 4, 3, 2, 1}
table.sort(r)
show(r)                                    -- 1,2,3,4,5

-- Edge sizes.
table.sort({42}); show({42})               -- 42
local empty = {}; table.sort(empty); show(empty)  -- (empty)

-- All-equal keys must not loop forever.
local equal = {5, 5, 5, 5, 5}
table.sort(equal)
show(equal)                                -- 5,5,5,5,5

-- Larger input: 100 elements in reverse order, sorted ascending.
local big = {}
for i = 1, 100 do big[i] = 101 - i end
table.sort(big)
local ok = true
for i = 1, 100 do if big[i] ~= i then ok = false end end
print(ok)                                  -- true

-- Comparator errors propagate (catchable).
local x = {1, 2, 3}
local caught = pcall(table.sort, x, function() error("bad") end)
print(caught)                              -- false
