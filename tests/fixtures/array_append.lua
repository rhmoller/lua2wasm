-- `t[#t + 1] = v` and `t[i] = v` growing an array: `#t` read inline for a
-- plain table, the append done inline when the array has room and nothing
-- else could see it (src/codegen/arrays.c) — and every case that must not.

local function build(n)
  local t = {}
  for i = 1, n do t[#t + 1] = i * 2 end
  return t
end
local t = build(1000)
print("append", #t, t[1], t[500], t[1000])

local g = {}
for i = 1, 1000 do g[i] = i end
print("grow", #g, g[1000])

-- __newindex sees every append (the key is absent)
local log = {}
local watched = setmetatable({}, {__newindex = function(tab, k, v) log[#log + 1] = k; rawset(tab, k, v) end})
for i = 1, 3 do watched[#watched + 1] = i end
print("newindex", #watched, table.concat(log, ","))

-- __len decides the key
local lenmt = setmetatable({}, {__len = function() return 10 end})
lenmt[#lenmt + 1] = "x"
print("__len", rawget(lenmt, 11), rawlen(lenmt))
local flen = setmetatable({}, {__len = function() return 1.5 end})
flen[#flen + 1] = "y"
print("float len", flen[2.5])

-- integer keys waiting in the hash part are absorbed
local h = {}
h[2], h[3] = "b", "c"
h[1] = "a"
h[#h + 1] = "d"
print("absorb", #h, h[1], h[2], h[3], h[4])
local mix = {x = 1}
for i = 1, 5 do mix[#mix + 1] = i end
print("with fields", #mix, mix[5], mix.x)

-- nil appends are no-ops; holes and shrinking
local nils = {1, 2}
nils[#nils + 1] = nil
print("nil", #nils)
local shrink = {1, 2, 3, 4}
shrink[#shrink] = nil
shrink[#shrink + 1] = "new"
print("shrink", #shrink, shrink[4])

-- strings have a length too; anything else raises
local s = "abc"
local keyed = {}
keyed[#s + 1] = "four"
print("string len", keyed[4])
print("bad", (pcall(function() local n = 5; local q = {} ; q[#n + 1] = 1 end)))

-- floats appended, then read back
local f = {}
for i = 1, 5 do f[#f + 1] = i / 4 end
print("floats", #f, f[1], f[5], math.type(f[5]))

-- an array kept in a field and appended through it
local obj = {items = {}}
for i = 1, 4 do obj.items[#obj.items + 1] = i * i end
print("field", #obj.items, table.concat(obj.items, " "))
