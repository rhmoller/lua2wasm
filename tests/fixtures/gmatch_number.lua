-- string.gmatch coerces a number subject/pattern to its string form, like
-- reference Lua (string.find/gmatch follow luaL_checkstring); a non-string,
-- non-number argument raises a catchable error instead of trapping.
local function collect(...)
  local t = {}
  for m in string.gmatch(...) do t[#t + 1] = m end
  return table.concat(t, ",")
end
local function err(...)
  local ok, e = pcall(string.gmatch, ...)
  return ok, type(e) == "string"
end
print(collect(12345, "%d"))             -- 1,2,3,4,5
print(collect(1234, "%d%d"))            -- 12,34
print(collect("a1b2c3", "%d"))          -- 1,2,3
print(collect("x97y97z", 97))           -- 97,97  (numeric pattern coerced)
print(err({}, "%d"))                    -- false true  (table subject errors)
print(err("x", true))                   -- false true  (bool pattern errors)
-- multi-capture form still yields each capture
for k, v in string.gmatch("k1=v1,k2=v2", "(%w+)=(%w+)") do
  print(k, v)
end
