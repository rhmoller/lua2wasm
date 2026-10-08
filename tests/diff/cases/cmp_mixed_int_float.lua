-- Int vs float comparisons are exact in Lua (no rounding of the integer to a
-- double). The specialized lowering compares a float with a small integer
-- literal as f64 and otherwise calls the exact mixed helpers; this pins every
-- operator, both operand orders, and the values where a naive f64 conversion
-- goes wrong (beyond 2^53, at 2^63, NaN, -0.0, infinities).
local function row(a, b)
  return table.concat({tostring(a < b), tostring(a <= b), tostring(a > b),
                       tostring(a >= b), tostring(a == b), tostring(a ~= b)}, " ")
end

-- maybe-typed operands (values read from a table, then arithmetic)
local ints = {0, 1, -1, 3, 2^53 // 1, 2^53 // 1 + 1, math.maxinteger, math.mininteger}
local floats = {0.0, -0.0, 0.5, 1.0, -1.5, 3.0, 2.0^53, 2.0^53 + 2, 2.0^63, -2.0^63,
                math.huge, -math.huge, 0 / 0}
for _, iv in ipairs(ints) do
  for _, fv in ipairs(floats) do
    local i, f = iv + 0, fv + 0.0
    local label = fv ~= fv and "nan" or string.format("%.17g", fv)
    print(iv, label, row(i, f), "|", row(f, i))
  end
end

-- float-typed locals against integer literals, in conditions and as values
local x = 0.25
local hits = {}
for step = 1, 12 do
  x = x * 2.0
  if x > 1 then hits[#hits + 1] = "gt1" end
  if 4 <= x then hits[#hits + 1] = "ge4" end
  if x < 600 then hits[#hits + 1] = "lt600" end
  if x == 8 then hits[#hits + 1] = "eq8" end
  if 16 ~= x then hits[#hits + 1] = "ne16" end
  hits[#hits + 1] = tostring(x >= 128) .. step
end
print(table.concat(hits, ","))

-- literals beyond 2^53 cannot be compared as doubles
local big = 2.0^53
print(big < 9007199254740993, big == 9007199254740992, big >= 9007199254740993)
print(9007199254740993 > big, 9007199254740993 == big, math.maxinteger < 2.0^63)
local neg = -2.0^63
print(neg == math.mininteger, neg < -9223372036854775807, -9223372036854775807 > neg)

-- float-typed vs int-typed locals
local n = 3
local h = 2.5
for _ = 1, 2 do h = h + 0.5 end
print(h == n, h < n, h <= n, n >= h, n ~= h)
