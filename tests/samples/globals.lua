-- Adapted from lua.org/extras' globals.lua. The original walks Lua's `_G`
-- and uses table.sort; our compiler doesn't expose either, so this walks a
-- sample table instead and prints keys in insertion order (which our
-- linear-probe hash table happens to preserve).

local seen = {}

local function dump(t, indent)
  seen[t] = true
  for k, v in pairs(t) do
    print(indent .. k)
    if type(v) == "table" and not seen[v] then
      dump(v, indent .. "  ")
    end
  end
end

local sample = {
  alpha = 1,
  beta = "hi",
  nested = {x = 10, y = 20},
  gamma = true,
}
dump(sample, "")
