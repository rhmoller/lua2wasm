-- The inline array-part paths of integer-key reads and writes
-- (src/codegen/arrays.c): every case where the probe must miss and the
-- helper take over, with int-typed keys, maybe-typed keys and float values.

-- holes read nil and fall through to __index
local function holes()
  local t = setmetatable({1, 2, 3, 4}, {__index = function(_, k) return "idx" .. k end})
  t[2] = nil
  local out = {}
  for i = 0, 6 do out[#out + 1] = tostring(t[i]) end
  print("holes", table.concat(out, " "))
end
holes()

-- a present slot is overwritten raw even with __newindex; a hole is not
local function newindex()
  local log = {}
  local t = setmetatable({10, 20, 30}, {__newindex = function(t, k, v) log[#log + 1] = k; rawset(t, k, v) end})
  for i = 1, 3 do t[i] = t[i] + 1 end
  t[2] = nil
  t[2] = 99
  t[4] = 40
  print("newindex", t[1], t[2], t[3], t[4], table.concat(log, ","))
end
newindex()

-- nil stores trim the border; appends and sparse keys take the helper
local function trim()
  local t = {}
  for i = 1, 8 do t[i] = i * i end
  for i = 8, 5, -1 do t[i] = nil end
  print("trim", #t, t[4], t[5])
  t[6] = 36
  print("sparse", #t, t[6])
  t[5] = 25
  print("filled", #t, t[5], t[6])
end
trim()

-- keys outside 1..#array: zero, negative, huge, minimum integer
local function edges()
  local t = {1, 2, 3}
  local keys = {0, -1, 4, 1 << 40, math.mininteger, math.maxinteger}
  for _, k in ipairs(keys) do t[k] = k end
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = tostring(t[k] == k) end
  print("edges", table.concat(out, " "), #t >= 3)
end
edges()

-- the destination is the key's own cell
local function chase()
  local nxt = {3, 1, 4, 2}
  local i, path = 1, {}
  for _ = 1, 6 do i = nxt[i]; path[#path + 1] = i end
  print("chase", table.concat(path, " "))
end
chase()

-- a maybe-typed key that turns float, string, then int again
local function mixed()
  local t = {"a", "b", "c", s = "str"}
  local k = 1
  local out = {}
  for step = 1, 5 do
    out[#out + 1] = tostring(t[k])
    if step == 1 then k = 2.0 elseif step == 2 then k = "s" elseif step == 3 then k = 2.5 else k = 3 end
  end
  print("mixed", table.concat(out, " "))
end
mixed()

-- float slots: int -> float -> float -> boxed -> float, read as cells and values
local function floats()
  local t = {0, 0, 0}
  for i = 1, 3 do t[i] = i / 2 end
  for i = 1, 3 do t[i] = t[i] * 3 end
  t[2] = "x"
  t[2] = 7.25
  local sum = 0
  for i = 1, 3 do sum = sum + t[i] end
  print("floats", t[1], t[2], t[3], sum, math.type(t[3]))
end
floats()

-- non-table receivers: a string indexes through its metatable, nil errors
local function receivers()
  local s = "hello"
  local i = 1
  print("string", s[i], s[2])
  local ok, err = pcall(function() local n = nil; return n[i] end)
  print("nil", ok, err ~= nil)
  ok, err = pcall(function() local n = 5; n[i] = 1 end)
  print("set nil", ok, err ~= nil)
end
receivers()

-- nested reads: a key that is itself an inline read
local function nested()
  local a, b = {10, 20, 30}, {3, 2, 1}
  local out = {}
  for i = 1, 3 do out[i] = a[b[i]] + b[a[1] // 10] end
  print("nested", table.concat(out, " "))
end
nested()
