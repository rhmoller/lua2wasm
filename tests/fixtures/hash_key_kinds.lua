-- Hash-part keys of every kind, crowded enough to share probe chains: a
-- small integer, a table, a boolean or a function only ever equals itself
-- (stored integer keys are normalized), a wide integer or a float compares
-- by value — an integral float finds the integer key and back.

local t = {}
local tabs, fns = {}, {}
for i = 1, 200 do
  t[i * 7919] = "small" .. i                      -- sparse small integers
  t[(1 << 40) + i] = "wide" .. i                  -- integers past i31
  t[i + 0.5] = "half" .. i                        -- non-integral floats
  t[-i * 13] = "neg" .. i
  tabs[i] = {}
  t[tabs[i]] = "tab" .. i
  fns[i] = function() return i end
  t[fns[i]] = "fn" .. i
end
t[true], t[false] = "T", "F"

local miss = 0
for i = 1, 200 do
  if t[i * 7919] ~= "small" .. i then miss = miss + 1 end
  if t[(i * 7919) + 0.0] ~= "small" .. i then miss = miss + 1 end  -- integral float finds the integer
  if t[(1 << 40) + i] ~= "wide" .. i then miss = miss + 1 end
  if t[2.0 ^ 40 + i] ~= "wide" .. i then miss = miss + 1 end      -- and a wide one
  if t[i + 0.5] ~= "half" .. i then miss = miss + 1 end
  if t[-i * 13] ~= "neg" .. i then miss = miss + 1 end
  if t[tabs[i]] ~= "tab" .. i then miss = miss + 1 end
  if t[fns[i]] ~= "fn" .. i then miss = miss + 1 end
end
print("found", miss, t[true], t[false])

-- absent keys of each kind, including look-alikes
print("absent", t[7919 * 201], t[(1 << 40) + 201], t[0.25], t[{}], t[function() end], t[7919.5])

-- a float key stored as an integer comes back as one
local f = {}
f[2.0 ^ 33] = "x"
f[3.0] = "y"
local kinds = {}
for k, v in pairs(f) do kinds[#kinds + 1] = math.type(k) .. ":" .. v end
table.sort(kinds)
print(table.concat(kinds, " "))

-- deleting and re-adding through the other representation
t[7919 * 3] = nil
t[(7919 * 3) + 0.0] = "again"
t[(1 << 40) + 5] = nil
t[2.0 ^ 40 + 5] = "wide again"
print("readd", t[7919 * 3], t[(1 << 40) + 5])
local n = 0
for _ in pairs(t) do n = n + 1 end
print("count", n)
