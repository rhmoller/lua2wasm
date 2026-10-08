-- %.<p>f must print exactly what C's printf prints (correctly rounded,
-- ties to even on the exact binary value) for every double, precision,
-- flag and width. A property sweep hashes thousands of renderings per
-- precision; the edge cases are printed in full.
local function h(acc, s)
  for i = 1, #s do acc = (acc * 31 + s:byte(i)) % 4294967296 end
  return acc
end
local seed = 12345
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end

local values = {}
for _ = 1, 600 do
  local a, b = rnd(), rnd() % 9999 + 1
  local k = rnd() % 33 - 12
  local x = a / b * 10.0 ^ k
  if rnd() % 2 == 0 then x = -x end
  values[#values + 1] = x
end
for k = 1, 30 do                       -- exact ties: odd multiples of 2^-k
  for n = 0, 6 do values[#values + 1] = (2 * n + 1) / 2 ^ k end
end
for e = -1074, 1023, 37 do values[#values + 1] = 2.0 ^ e end
for _, v in ipairs({0.0, -0.0, 0.5, 1.5, 2.5, -2.5, 0.125, 0.375, 1e15 + 0.5, 2^53, 2^53 + 2,
                    2^63, 2^64, 1.8446744073709552e19, 1.8e19, 9.999999999999999e18,
                    5e-324, 2.2250738585072014e-308, 1e-300, 123456789.123456789, 0.1, 0.7,
                    1 / 3, 2 / 3, 1e22, 1e23, 4.35, 2.675, 1.005, 1.045}) do
  values[#values + 1] = v
end

for p = 0, 15 do
  local acc = 0
  for _, x in ipairs(values) do acc = h(acc, string.format("%." .. p .. "f", x)) end
  print("p" .. p, #values, acc)
end
local flagsets = {"", "-", "+", " ", "0", "#", "-+", "+0", " 0", "#0", "-#"}
local acc = 0
for _, f in ipairs(flagsets) do
  for _, w in ipairs({"", "1", "8", "25"}) do
    for _, p in ipairs({"", ".0", ".2", ".6"}) do
      for i = 1, #values, 7 do acc = h(acc, string.format("%" .. f .. w .. p .. "f", values[i])) end
    end
  end
end
print("flags", acc)

for _, spec in ipairs({"%.0f", "%.1f", "%.2f", "%.3f", "%f", "%+.2f", "% .1f", "%010.3f", "%-10.2f|",
                       "%#.0f", "%5.0f", "%.13f", "%.14f"}) do
  print(spec, string.format(spec, 0.125), string.format(spec, -0.0), string.format(spec, 2.5),
        string.format(spec, 1e15 + 0.5), string.format(spec, 2^63), string.format(spec, 5e-324),
        string.format(spec, -1234.5678), string.format(spec, 7))
end
print(string.format("%.3f %.3f %.3f", 1/0, -1/0, 3), string.format("%5.1f|%-7.2f|%07.1f", 1/0, -1/0, -1/0))
