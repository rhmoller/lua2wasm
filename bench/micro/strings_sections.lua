-- bench/strings.lua cut into sections, each timed once at the top level of
-- the main chunk: the cold costs the benchmark sees (docs/perf-backlog.md).
-- bench/micro/strings_warm.lua times the same sections warmed up.
-- Compare with reference Lua: scripts/micro.sh bench/micro/strings_sections.lua
local clock = os.clock
local t = clock()
local function lap(name)
  print(string.format("%-8s %6.1f ms", name, (clock() - t) * 1000))
  t = clock()
end

local words = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa"}
local parts, seed = {}, 42
for i = 1, 200000 do
  seed = (seed * 1103515245 + 12345) % 2147483648
  parts[#parts + 1] = words[seed % #words + 1] .. (seed % 7)
end
lap("build")
local text = table.concat(parts, " ")
lap("tconcat")
local freq = {}
for w in string.gmatch(text, "%a+%d") do freq[w] = (freq[w] or 0) + 1 end
lap("gmatch")
local s2 = text:sub(1, 200000):gsub("a", "A"):upper()
lap("gsub")
local n = 0
for i = 1, #s2 do n = n + s2:byte(i) end
lap("byte")
local acc = ""
for i = 1, 20000 do acc = acc .. tostring(i % 10) end
lap("concat")
local fs = {}
for i = 1, 100000 do fs[i] = string.format("%5d:%8.3f:%s", i, i / 7, "x") end
lap("format")
print("check", #text, n, #acc, fs[100000])
