-- Results built in one allocation: table.concat's sized fast path (and its
-- fallback to the general path), and the scratch builder string.format /
-- gsub / table.concat share — re-entered from __tostring, gsub callbacks and
-- __index, abandoned by an error, and grown past the size it is kept at.

-- table.concat over the array part: strings, integers, separators, ranges
local mi, ma = math.mininteger, math.maxinteger
print(table.concat({"a", "bc", "", "def"}), table.concat({"a", "bc", "", "def"}, ", "))
print(table.concat({1, -2, 0, 30, -400, ma, mi, 2^31 | 0, -(2^40 | 0)}, "|"))
print(table.concat({"x", 1, "y", -1, "z"}, ""), table.concat({7}, "sep"), table.concat({}, "sep") == "")
print(table.concat({1, 2, 3}, 0), table.concat({1, 2, 3}, -1.5), table.concat({"a", "b"}, "\0"):byte(1, -1))
local r = {"a", "b", "c", "d", "e"}
print(table.concat(r, "-", 2), table.concat(r, "-", 2, 4), table.concat(r, "-", 3, 3),
      table.concat(r, "-", 4, 2) == "", table.concat(r, "-", 5))
print((pcall(table.concat, r, "-", 0, 2)), (pcall(table.concat, r, "-", 4, 6)))
-- the general path: floats, holes, other values, the hash part, metatables
print(table.concat({1, 2.5, "x", 3.0, -0.0, 1e100}, " "))
print((pcall(table.concat, {1, nil, 3}, ",", 1, 3)), (pcall(table.concat, {"a", true, "c"})),
      (pcall(table.concat, {"a", {}, "c"})))
local sparse = {}
sparse[1], sparse[2], sparse[100], sparse[3] = "s1", "s2", "s100", "s3"
print(table.concat(sparse, ",", 1, 3), table.concat(sparse, ",", 100, 100), (pcall(table.concat, sparse, ",", 99, 100)))
local log = {}
local proxy = setmetatable({"p1"}, {__index = function(t, k)
  log[#log + 1] = k
  return "i" .. k
end})
print(table.concat(proxy, ",", 1, 4), table.concat(log, " "))
local withmt = setmetatable({"m1", "m2", 3}, {})
print(table.concat(withmt, "+"))
local big = {}
for i = 1, 5000 do big[i] = i % 3 == 0 and i or ("w" .. i) end
local s = table.concat(big, ",")
print(#s, s:sub(1, 30), s:sub(-30))

-- string.format with nested calls while the builder is taken
local T = setmetatable({}, {__tostring = function()
  return string.format("<%s:%d:%5.2f>", "inner", 42, 1.5)
end})
print(string.format("[%s] [%s] %d", T, T, 7))
local deep = setmetatable({}, {__tostring = function()
  return string.format("%s", setmetatable({}, {__tostring = function()
    return table.concat({"x", string.format("%03d", 5), ("abc"):gsub("b", "B")}, "/")
  end}))
end})
print(string.format("%s|%s", deep, "tail"))
-- an error in the middle of a format, then formats that must start clean
print((pcall(string.format, "%s %d %s", "a", 1.5, "c")),
      (pcall(string.format, "%d %s", 1, setmetatable({}, {__tostring = function() error("boom") end}))))
print(string.format("%d-%s", 9, "ok"), string.format("x"))
-- digits: zero fill, precision, bases, signs, mininteger
print(string.format("%.10f|%.3f|%f|%.0f|%5.1f|%-8.2f|%08.3f", 1e-5, 0.0005, 0, 2.5, -0.04, 3.14159, -1.5))
print(string.format("%.13f|%.13f|%.1f|%.2f", 1/3, 2^-20, 0.05, 1e15 + 0.125))
print(string.format("%x|%X|%o|%#o|%#x|%.0d|%05d|%+d|% d|%.3d", mi, 255, -1, 0, 255, 0, -42, 5, 5, 7))
print(string.format("%d|%i|%u|%5d|%-5d|", mi, ma, 3, -12, 12))
-- results over 64 KB, then small ones again
local long = string.format("%s%s", string.rep("y", 70000), "!")
print(#long, long:sub(-3), string.format("%s=%d", "k", 1), string.format("%5s|", "ab"))

-- gsub: no match returns the subject, callbacks that format and gsub
print(string.gsub("hello", "z", "Z"))
print(string.gsub(123, "x", "y"), math.type((string.gsub(123, "x", "y"))))
print(string.gsub("", "x", "y"), string.gsub("abc", "^b", "B"))
print(string.gsub("a,b,c", "%w", function(c)
  return string.format("%s%d", c:upper(), #c) .. (c:gsub(".", "%0%0"))
end))
print(string.gsub("x y z", "%w", {x = "1", y = true and "two"}))
print(string.gsub("abc", "%w", function() return nil end))
print((pcall(string.gsub, "abc", "%w", function(c)
  if c == "b" then error("stop at " .. c) end
  return c
end)))
print(string.gsub("after error", "e", "E"), string.gsub("aaa", "", "-"))
print(select("#", string.gsub("q", "z", "")), string.gsub("one two", "(%w+)", "<%1>", 1))
local huge = string.rep("ab", 40000)
local hg, n = huge:gsub("a", "A")
print(#hg, n, hg:sub(1, 6), (string.gsub("small", "m", "M")))
