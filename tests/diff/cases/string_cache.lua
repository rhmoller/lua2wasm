-- Short strings made at run time go through a lossy cache (a match or
-- capture, string.sub, a short `..` result, an integer's digits) and
-- one-byte strings through a table of all 256: equal strings may come back
-- as one object, which must never be observable — every string still has
-- exactly its own bytes, compares and hashes by them, and works as a key.

local function show(s)  -- the bytes, printable
  return (s:gsub("[^%w%p ]", function(c) return string.format("\\%d", c:byte()) end))
end

-- lengths around the cache's limits, every byte value as a one-byte string
local probe = string.rep("x", 39)
for _, s in ipairs({"", "a", "ab", probe, probe .. "y", probe .. "yz", probe .. "yzw"}) do
  local t = s:sub(1)
  io.write(#s, ":", tostring(t == s), ":", #(s .. ""), " ")
end
print()
local all, back = {}, {}
for b = 0, 255 do all[#all + 1] = string.char(b) end
local s256 = table.concat(all)
local ok = true
for b = 0, 255 do
  local c1, c2, c3 = s256:sub(b + 1, b + 1), string.char(b), s256:match(".", b + 1)
  if c1 ~= c2 or c2 ~= c3 or #c1 ~= 1 or c1:byte() ~= b then ok = false end
  back[c1] = b
end
local n = 0
for k, v in pairs(back) do if k:byte() == v then n = n + 1 end end
print(ok, n, back["\0"], back["\255"], back["a"], back["\0"] == 0)

-- strings that share a length and most bytes compete for slots; each must
-- still read back as itself, as a key and as a value
local keys, vals = {}, {}
for i = 1, 3000 do
  local k = "k" .. (i % 7) .. "-" .. i % 97 .. ":" .. i
  keys[i] = k
  vals[k] = i
end
local bad = 0
for i = 1, 3000 do
  local k = "k" .. (i % 7) .. "-" .. i % 97 .. ":" .. i      -- built again
  if vals[k] ~= i or k ~= keys[i] or #k ~= #keys[i] then bad = bad + 1 end
end
print("collisions", bad)

-- the same string from every path, used as one key
local text = "alpha beta alpha gamma beta alpha"
local count = {}
for w in text:gmatch("%a+") do count[w] = (count[w] or 0) + 1 end
count[text:sub(1, 5)] = count[text:sub(1, 5)] + 10                  -- "alpha"
count["al" .. "pha"] = count["al" .. "pha"] + 100
count[("ALPHA"):lower()] = count[("ALPHA"):lower()] + 1000
count[select(3, text:find("(b%a+)"))] = count.beta + 1               -- "beta"
local names = {}
for k in pairs(count) do names[#names + 1] = k end
table.sort(names)
for _, k in ipairs(names) do io.write(k, "=", count[k], " ") end
print()

-- integers' digits: repeated and unique, negative, extremes, as keys
local digits = {}
for i = -50, 50 do digits[tostring(i % 13)] = (digits[tostring(i % 13)] or 0) + 1 end
local dk = {}
for k in pairs(digits) do dk[#dk + 1] = k end
table.sort(dk, function(a, b) return tonumber(a) < tonumber(b) end)
for _, k in ipairs(dk) do io.write(k, ":", digits[k], " ") end
print()
print(tostring(math.mininteger), tostring(math.maxinteger), tostring(-0), tostring(-1) .. tostring(1),
      math.mininteger .. "", 12 .. 34, (12 .. 34) == "1234", ("12" .. 34) == (12 .. "34"))

-- many unique strings (each kind switches its probing off), then repeats
local u = {}
for i = 1, 5000 do u[i] = "u" .. i end
local seen = {}
for i = 1, 5000 do seen[u[i]] = true end
local hits = 0
for i = 1, 5000 do if seen["u" .. i] then hits = hits + 1 end end
for r = 1, 3 do
  for i = 1, 200 do
    local w = ("w" .. (i % 5)):sub(1)
    seen[w] = (seen[w] == true and 0 or seen[w] or 0) + 1
  end
end
print(hits, seen.w0, seen.w4, seen.w5)

-- embedded zeros and bytes that look alike
local z1, z2 = "a\0b", "a\0c"
local zt = {[z1] = 1, [z2] = 2, ["a\0"] = 3, ["\0b"] = 4}
print(zt[("xa\0bx"):sub(2, 4)], zt[("a\0c")], zt["a" .. "\0"], zt["\0" .. "b"], show(z1 .. z2))
print(("a\0b"):sub(1, 2) == "a\0", ("a\0b"):sub(2) == "\0b", #("\0"):rep(40), #("\0"):rep(41))

-- comparisons between cached and uncached strings of the same bytes
local long = string.rep("q", 40)
local a1, a2 = long:sub(1, 20), ("q"):rep(20)
local b1, b2 = long:sub(1, 2) .. long:sub(3, 20), long:sub(1, 20)
print(a1 == a2, a1 == b1, b1 == b2, a1 < a2 .. "a", a1 .. "" == a2 .. "", rawequal(a1, a2))

-- strings that agree in length and at the start, middle and end, so they
-- all want one slot: "ab" .. 3 digits .. "|" .. 2 digits .. "de"
local same, back2 = {}, {}
for i = 0, 999 do
  local d = string.format("%05d", i * 37 % 100000)
  local s = "ab" .. d:sub(1, 3) .. "|" .. d:sub(4, 5) .. "de"
  same[i] = s
  back2[s] = i
end
local wrong = 0
for i = 0, 999 do
  local d = string.format("%05d", i * 37 % 100000)
  local again = ("xab" .. d:sub(1, 3) .. "|" .. d:sub(4, 5) .. "dex"):sub(2, -2)
  if back2[again] ~= i or again ~= same[i] then wrong = wrong + 1 end
end
print("one slot", #same[0], wrong)
