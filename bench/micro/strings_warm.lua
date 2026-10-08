-- The sections of bench/micro/strings_sections.lua inside a function run three
-- times: the first column is the first run, the second the third (warmed up)
-- run. A section much faster warm pays mostly warm-up (GC heap growth, code
-- not yet optimized); one slow even warm has a steady-state cost.
-- (The first run here is a little worse than strings_sections.lua's: a loop in
-- a function called repeatedly isn't outlined, so it starts on baseline code.)
-- Compare with reference Lua: scripts/micro.sh bench/micro/strings_warm.lua
local clock = os.clock
local words = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa"}

local function round()
  local laps, t = {}, clock()
  local function lap(name)
    laps[#laps + 1] = string.format("%-8s %6.1f ms", name, (clock() - t) * 1000)
    t = clock()
  end
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
  return laps
end

local first, warm = round(), nil
for _ = 2, 3 do warm = round() end
print(string.format("%-20s %s", "first run", "warm run"))
for i = 1, #first do print(first[i], warm[i]) end
