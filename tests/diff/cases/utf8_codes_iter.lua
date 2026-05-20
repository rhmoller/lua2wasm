-- utf8.codes iterator: an out-of-range position must yield nil (never an
-- uncatchable wasm trap, which is what lua2wasm did for negative positions);
-- an invalid UTF-8 sequence must raise a *catchable* error.

-- Out-of-range positions return nil. (f("",2)/f("",-1)/mininteger used to
-- trap or error; reference just stops.)
local f = utf8.codes("")
print(f("", 2) == nil, f("", -1) == nil, f("", math.mininteger) == nil)
local g = utf8.codes("ab")
print(g("ab", 5) == nil, g("ab", -1) == nil)

-- Normal iteration (a=1B, λ=2B, b=1B, €=3B).
local out = {}
for p, c in utf8.codes("aλb€") do out[#out + 1] = p .. ":" .. c end
print(table.concat(out, " "))

-- Direct iterator calls thread the byte position and skip continuation bytes.
local h = utf8.codes("aλb")
print(h("aλb", 0))      -- 1 97
print(h("aλb", 2))      -- 4 98

-- Invalid sequences raise a catchable error (string), never a trap.
local function bad(s)
  local ok, err = pcall(function() for _ in utf8.codes(s) do end end)
  return ok, type(err)
end
print(bad("a\x80b"))    -- false string  (stray continuation after 'a')
print(bad("\xbfz"))     -- false string  (leading continuation)
print(bad("a\xC0"))     -- false string  (truncated)
