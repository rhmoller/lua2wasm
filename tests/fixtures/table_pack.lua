-- table.pack(...) — returns { [1]=a1, ..., [n]=an, n = nargs }

local t = table.pack(10, 20, 30)
print(t.n, t[1], t[2], t[3])           -- 3   10   20   30

-- Zero args.
local empty = table.pack()
print(empty.n, empty[1])               -- 0   nil

-- A single nil arg: n is 1, even though the slot is nil.
local one = table.pack(nil)
print(one.n, one[1])                   -- 1   nil

-- Holes (nil mid-args): n preserves the real count, unlike #t.
local mixed = table.pack("a", nil, "c")
print(mixed.n, mixed[1], mixed[2], mixed[3]) -- 3   a   nil   c

-- pack/unpack round-trip with multi-return.
local function f() return 1, 2, 3 end
local p = table.pack(f())
print(p.n)                              -- 3
print(table.unpack(p, 1, p.n))          -- 1   2   3

-- Result is a fresh table each call.
local a = table.pack(1)
local b = table.pack(1)
print(rawequal(a, b))                   -- false
