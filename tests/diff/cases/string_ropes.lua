-- Long `..` results are ropes until their bytes are read: every way of
-- building one (append, prepend, both, chains of three and four, numbers,
-- ropes of ropes) and every way of reading one must see the same string as
-- a flat copy would be.

local function sum(s)   -- a checksum over every byte, read in chunks
  local h = 0
  for i = 1, #s, 4000 do
    local t = {s:byte(i, math.min(i + 3999, #s))}
    for k = 1, #t do h = (h * 31 + t[k]) % 1000000007 end
  end
  return h
end

-- append: `acc = acc .. x`, read only at the end
local acc = ""
for i = 1, 3000 do acc = acc .. (i % 10) end
print(#acc, acc:sub(1, 12), acc:sub(-12), sum(acc))
-- prepend: a rope that leans the other way (a deep flatten)
local pre = ""
for i = 1, 3000 do pre = (i % 7) .. pre end
print(#pre, pre:sub(1, 12), pre:sub(-12), sum(pre))
-- both ends, and chains of three and four operands
local mid = "[" .. string.rep("m", 140) .. "]"
for i = 1, 200 do
  if i % 2 == 0 then mid = "<" .. i .. mid .. i .. ">" else mid = mid .. "," .. i end
end
print(#mid, mid:sub(1, 20), mid:sub(-20), sum(mid))
-- numbers inside long results: integers, floats, the extremes
local nums = string.rep("n", 120)
nums = nums .. math.mininteger .. "|" .. math.maxinteger .. "|" .. 1.5 .. "|" .. -0.0 .. "|" .. 1e300
print(#nums, nums:sub(115))

-- the length never needs the bytes; reading them afterwards still works
local r = string.rep("ab", 70) .. string.rep("cd", 70)
print(#r, r:len(), string.len(r), rawlen(r), select("#", r:byte(1, -1)))
print(r:sub(139, 142), r:find("bc"), r:find("dc", 1, true), r:match("(b+c)"))

-- equality: against flat and rope copies, of the same and other lengths
local a1 = string.rep("x", 130) .. "y"
local a2 = string.rep("x", 100) .. string.rep("x", 30) .. "y"
local flat = string.rep("x", 130) .. ""   -- a rope over a flat string and ""
local b1 = string.rep("x", 131)
print(a1 == a2, a1 ~= a2, a1 == b1, a1 == a1 .. "", #a1 == #b1, rawequal(a1, a2))
print(a1 < b1, b1 < a1, a1 <= a2, (a1 .. "z") > a1, flat == string.rep("x", 130))

-- as table keys: stored as a rope, found with a flat copy and the reverse
local t = {}
t[string.rep("k", 100) .. string.rep("K", 50)] = "rope key"
local flatkey = string.rep("k", 100) .. string.rep("K", 50)
print(t[flatkey], t[string.rep("k", 100) .. string.rep("K", 50)])
t[string.rep("q", 200)] = 1
t[string.rep("q", 150) .. string.rep("q", 50)] = (t[string.rep("q", 150) .. string.rep("q", 50)] or 0) + 1
local n = 0
for k, v in pairs(t) do n = n + 1 end
print(n, t[string.rep("q", 200)])

-- the string library, formatting, conversions
local s = string.rep("Hello, ", 20) .. "World!"
print(s:upper():sub(1, 14), s:lower():sub(-12), s:rep(2):len(), s:reverse():sub(1, 6))
print((s:gsub("Hello", "Bye")):sub(1, 20), select(2, s:gsub("l", "L")), s:gmatch("%a+")())
print(string.format("%s|%.5s|%5.3s|", s, s, s):len(), string.format("%q", s:sub(1, 10) .. string.rep("\n", 130)):len())
print(tostring(s) == s, type(s), tonumber(string.rep("1", 130) .. "") ~= nil, math.type(#s))
print(utf8.len(string.rep("é", 100) .. string.rep("ü", 50)), #(string.rep("é", 100) .. string.rep("ü", 50)))
local packed = string.pack("s4", string.rep("p", 64) .. string.rep("P", 64))
print(#packed, string.unpack("s4", packed):sub(60, 70))

-- table.concat with rope elements and a rope separator
local parts = {acc, "|", pre, 42}
print(#table.concat(parts), sum(table.concat(parts)))
local sep = string.rep("-", 64) .. string.rep("=", 64)
print(#table.concat({"a", "b", "c"}, sep), table.concat({"a", "b"}, sep):sub(60, 70))

-- ropes of ropes, concatenated again after a read
local x = string.rep("1", 100) .. string.rep("2", 100)
local y = x .. x
print(#y, y:sub(195, 205))
local z = y .. x .. y
print(#z, sum(z), z == (y .. x) .. y)

-- errors carry long messages built by concatenation
local ok, msg = pcall(function() error(string.rep("e", 100) .. " " .. string.rep("E", 100), 0) end)
print(ok, #msg, msg:sub(98, 104))
local ok2, msg2 = pcall(function() return {} .. string.rep("w", 200) end)
print(ok2)
-- io.write and print of a rope
io.write(string.rep("w", 60) .. string.rep("W", 70), "\n")
print(string.rep(".", 64) .. string.rep(":", 64))

-- a seeded random mix of building and reading: the same operations in the
-- same order under any implementation, so the checksums must agree
local seed = 12345
local function rnd(n)
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed % n
end
for round = 1, 6 do
  local pool = {"", "a", string.rep("b", 50), string.rep("c", 127), string.rep("d", 128), "e" .. round}
  local h = 0
  for step = 1, 400 do
    local i, j = rnd(#pool) + 1, rnd(#pool) + 1
    local u, v = pool[i], pool[j]
    local op = rnd(10)
    local w
    if op == 0 then w = u .. v
    elseif op == 1 then w = v .. u .. step
    elseif op == 2 then w = u .. "|" .. v .. "|"
    elseif op == 3 and #u < 20000 then w = u .. u
    elseif op == 4 then w = u:sub(rnd(#u + 1), rnd(#u + 1) + 200)
    elseif op == 5 then w = (u .. v):upper()
    else w = step .. u .. 1.5 end
    if #w < 60000 then pool[rnd(#pool) + 1] = w end
    -- reads, some before any flattening
    h = (h * 7 + #w) % 1000000007
    if op % 3 == 0 then h = (h + (w:byte(rnd(#w + 1)) or 0)) % 1000000007 end
    if op % 4 == 0 then h = (h + (w == u .. v and 1 or 0) + (w < v and 2 or 0)) % 1000000007 end
  end
  local keys, kt = {}, {}
  for k = 1, #pool do kt[pool[k]] = (kt[pool[k]] or 0) + 1 end
  for k in pairs(kt) do keys[#keys + 1] = k end
  table.sort(keys)
  local all = table.concat(keys, "/")
  print(round, h, #keys, #all, sum(all))
end

-- versions of one append buffer: forks, old versions read after newer
-- appends, a string appended to itself, numbers appended in place
local base = string.rep("b", 100)
base = base .. string.rep("c", 50)          -- a node
base = base .. "-"                          -- a buffer now
local v1 = base .. "one"                    -- the buffer's next version
local v2 = base .. "two"                    -- base is no longer the latest: a fork
local v3 = v1 .. "three"                    -- v1 is the latest: in place
local v4 = v1 .. "four"                     -- a fork of v1
print(#base, #v1, #v2, #v3, #v4)
print(base:sub(-3), v1:sub(-5), v2:sub(-5), v3:sub(-10), v4:sub(-9))
local self = string.rep("s", 130) .. "|"
self = self .. "x"
self = self .. self
self = self .. self .. "!"
print(#self, self:sub(129, 136), self:sub(-6), sum(self))
local versions = {}
local grow = string.rep("g", 120) .. "0123456789"
for i = 1, 300 do
  grow = grow .. i .. ";"
  if i % 50 == 0 then versions[#versions + 1] = grow end
end
for i = 1, #versions do io.write(#versions[i], ":", versions[i]:sub(-8), " ") end
print()
print(versions[1] == grow:sub(1, #versions[1]), versions[6] == grow, sum(grow))
local old = versions[2]
grow = old .. "fork"
print(#grow, grow:sub(-12), #versions[3], versions[3]:sub(-8))
