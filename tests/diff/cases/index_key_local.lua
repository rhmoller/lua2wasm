-- A local whose only numeric-looking use is as a table key is lowered as a
-- maybe-typed slot (unboxed when it holds a number). Whatever it holds, reads
-- and writes through it must behave like any other key: integer and
-- integral-float keys normalize to the same entry, other floats, strings,
-- booleans and tables are distinct keys, NaN/nil reads miss and their stores
-- raise, and __index / __newindex still fire.
local keys = {1, 2, 3.0, 2.5, "x", "2", true, 0 / 0, -0.0, 2^53, math.maxinteger}
local t = {}
for i = 1, #keys do
  local k = keys[i]
  local ok, err = pcall(function() t[k] = i end)
  print(i, math.type(k) or type(k), ok, ok or (err:find("NaN") and "NaN key" or err))
end
for i = 1, #keys do
  local k = keys[i]
  print(i, t[k])
end
local n = 0
for k, v in pairs(t) do n = n + 1 end
print("entries", n, t[3], t[0], t["2"], t[2])

-- a nil key: reading misses, writing raises
local holes = {nil, 1}
local k = holes[1]
local ok, err = pcall(function() t[k] = 1 end)
print(t[k], ok, (err:gsub("^.-:%d+: ", ""))) -- chunk-name formatting isn't asserted

-- the array part: dense keys written through a key local stay a sequence
local arr = {}
local order = {1, 2, 3, 4, 5}
for i = 1, #order do
  local id = order[i]
  arr[id] = id * 1.5
  arr[id] = arr[id] + 1
end
print(#arr, arr[1], arr[5], table.concat(arr, " "))

-- metamethods still apply to absent keys
local log = {}
local proxy = setmetatable({}, {
  __index = function(_, key) log[#log + 1] = "get " .. tostring(key); return 0 end,
  __newindex = function(r, key, v) log[#log + 1] = "set " .. tostring(key); rawset(r, key, v) end,
})
local ids = {7, 7.0, "s"}
for i = 1, #ids do
  local id = ids[i]
  proxy[id] = proxy[id] + 1
end
print(table.concat(log, ","), proxy[7], proxy.s)
