-- Numeric-for limit handling (Lua 5.4+ forprep). With integer init and step
-- the loop is an integer loop whatever the limit is: a float limit is floored
-- (ceiled for a negative step), an out-of-range one is clipped or skips the
-- loop, a numeric string is coerced, and anything else raises "bad 'for'
-- limit". Otherwise every control value is coerced to a float. Each shape runs
-- through both lowerings: a plain loop (unboxed integer counter) and one whose
-- control variable is captured by a closure (boxed generic loop).
local NAN = 0 / 0

local function plain(lim, step)
  local n, last = 0, nil
  if step == 1 then
    for i = 1, lim do n = n + 1; last = i; if n > 5 then break end end
  else
    for i = 1, lim, -1 do n = n + 1; last = i; if n > 5 then break end end
  end
  return n .. " " .. tostring(last) .. " " .. tostring(math.type(last))
end

local function captured(lim, step)
  local fs = {}
  if step == 1 then
    for i = 1, lim do fs[#fs + 1] = function() return i end; if #fs > 5 then break end end
  else
    for i = 1, lim, -1 do fs[#fs + 1] = function() return i end; if #fs > 5 then break end end
  end
  local last = #fs > 0 and fs[#fs]() or nil
  return #fs .. " " .. tostring(last) .. " " .. tostring(math.type(last))
end

local limits = {
  {3, 1}, {3.7, 1}, {-3.7, 1}, {2.5, -1}, {-2.5, -1}, {3.0, 1},
  {NAN, 1}, {NAN, -1},
  {math.huge, 1}, {-math.huge, 1}, {math.huge, -1}, {-math.huge, -1},
  {2^63, 1}, {-2^63, -1}, {1e300, 1}, {-1e300, -1},
  {"3", 1}, {"3.5", 1}, {" 0x10 ", 1}, {"-2", -1},
}
for _, c in ipairs(limits) do
  local label = c[1] ~= c[1] and "nan" or tostring(c[1]) -- NaN's sign isn't portable
  print(label .. "/" .. c[2], plain(c[1], c[2]), captured(c[1], c[2]))
end

-- the limit expression is evaluated between init and step, once
local log = {}
local function v(x, tag) log[#log + 1] = tag; return x end
for i = v(1, "init"), v(2, "limit"), v(1, "step") do log[#log + 1] = "body" .. i end
print(table.concat(log, ","))

-- clipping at the integer range edges, both directions
local r = {}
for i = math.maxinteger - 1, math.huge do r[#r + 1] = i end
print(#r, r[1], r[2])
r = {}
for i = math.mininteger + 1, -math.huge, -1 do r[#r + 1] = i end
print(#r, r[1], r[2])

-- float loops: a NaN limit or init still runs the body exactly once
local n = 0
for _ = 1.0, NAN do n = n + 1 end
print("float init, NaN limit", n)
n = 0
for _ = NAN, 2 do n = n + 1 end
print("NaN init", n)
n = 0
for i = 1, NAN, 0.5 do n = n + 1; if n > 3 then break end end
print("float step, NaN limit", n)

-- numeric strings make the loop a float loop when they are init or step
for i = "1", 2 do print("string init", i, math.type(i)) end
for i = 1, 2, "1" do print("string step", i, math.type(i)) end

-- errors, in Lua's check order (step zero before a bad limit)
-- (chunk-name formatting isn't asserted; the line must be the loop's own)
local function try(f) local ok, e = pcall(f); print(ok, (e:gsub("^.-:(%d+):", "%1:"))) end
try(function() for _ = 1, {} do end end)
try(function() for _ = 1, nil do end end)
try(function() for _ = 1, "x" do end end)
try(function() for _ = 1, {}, 0 do end end)
try(function() for _ = 1, 3, 0 do end end)
try(function() for _ = {}, 2 do end end)
try(function() for _ = 1, 2, {} do end end)
try(function() for _ = 1.0, {} do end end)
try(function() local lim = {}; for i = 1, lim do local _ = function() return i end end end)
