-- strings: gmatch word count, string-keyed hash table, gsub/upper/byte,
-- repeated concatenation, and string.format in a loop.
local t0 = os.clock()
-- word frequency over generated text, string keys in hash tables
local words = {"alpha","beta","gamma","delta","epsilon","zeta","eta","theta","iota","kappa"}
local parts = {}
local seed = 42
for i = 1, 200000 do
  seed = (seed * 1103515245 + 12345) % 2147483648
  parts[#parts+1] = words[seed % #words + 1] .. (seed % 7)
end
local text = table.concat(parts, " ")
local freq = {}
for w in string.gmatch(text, "%a+%d") do
  freq[w] = (freq[w] or 0) + 1
end
local keys = {}
for k in pairs(freq) do keys[#keys+1] = k end
table.sort(keys)
local out = {}
for i = 1, #keys do out[#out+1] = string.format("%s=%d", keys[i], freq[keys[i]]) end
io.write(#out, " ", out[1], " ", out[#out], "\n")
-- gsub + upper + sub + byte
local s2 = text:sub(1, 200000):gsub("a", "A"):upper()
local n = 0
for i = 1, #s2 do n = n + s2:byte(i) end
io.write(n, "\n")
-- concat in a loop (quadratic-ish pattern people actually write)
local acc = ""
for i = 1, 20000 do acc = acc .. tostring(i % 10) end
io.write(#acc, "\n")
-- string.format heavy
local fs = {}
for i = 1, 100000 do fs[i] = string.format("%5d:%8.3f:%s", i, i / 7, "x") end
io.write(fs[100000], "\n")
io.write(string.format("TIME %.3f\n", os.clock()-t0))
