-- `a .. b .. c ...` chains of every length, with numbers converted the way
-- tostring would, __concat called pairwise from the right with the same
-- operands as reference Lua, parentheses keeping their grouping, and errors
-- for operands that can't be concatenated.
local log = {}
local M = {__concat = function(a, b)
  local function s(v) return type(v) == "table" and v.name or tostring(v) end
  log[#log + 1] = s(a) .. "+" .. s(b)
  return setmetatable({name = "(" .. s(a) .. s(b) .. ")"}, getmetatable(type(a) == "table" and a or b))
end}
local function obj(n) return setmetatable({name = n}, M) end

local x, y = 7, 2.5
print("a" .. "b" .. "c", "a" .. 1 .. "c", 1 .. 2 .. 3 .. 4, x .. y .. -x .. -0.0)
print("p" .. math.maxinteger .. "q" .. math.mininteger .. "r" .. 0 .. -1)
print(1e100 .. "|" .. 2^53 .. "|" .. 1/3 .. "|" .. 10 // 3 .. "|" .. 7.0)
local parts = {"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"}
local p = parts
print(p[1] .. p[2] .. p[3] .. p[4] .. p[5] .. p[6] .. p[7] .. p[8] .. p[9] .. p[10])
print((p[1] .. p[2]) .. p[3], p[1] .. (p[2] .. p[3]) .. p[4])

local function show(v) return type(v) == "table" and v.name or v end
for _, case in ipairs({
  function() return "a" .. obj("B") .. "c" end,
  function() return obj("A") .. "b" .. "c" .. obj("D") end,
  function() return "a" .. "b" .. obj("C") .. "d" .. "e" end,
  function() return (obj("A") .. "b") .. "c" end,
  function() return "x" .. 1 .. obj("O") .. 2.5 .. "y" .. 3 end,
}) do
  log = {}
  local r = case()
  print(show(r), table.concat(log, " "))
end

for _, bad in ipairs({
  function() return "a" .. nil .. "c" end,
  function() return "a" .. "b" .. {} .. "d" end,
  function() return 1 .. 2 .. true end,
}) do
  local ok, err = pcall(bad)
  print(ok, type(err)) -- error wording isn't asserted
end

-- evaluation order of the operands
local order = {}
local function v(tag, val) order[#order + 1] = tag; return val end
local s = v("1", "a") .. v("2", "b") .. v("3", 3) .. v("4", "d") .. v("5", "e")
print(s, table.concat(order, ""))
