-- Table constructors with constant field names are built on a per-site
-- cached layout. Everything a constructor can express must still come out
-- right: nil fields, duplicate names (the last one wins), computed keys,
-- positional items mixed in, a trailing multi-value splice, float values,
-- fields added afterwards, and many fields. Listings are sorted.
local function dump(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    if type(a) ~= type(b) then return type(a) < type(b) end
    return a < b
  end)
  local out = {}
  for _, k in ipairs(ks) do out[#out + 1] = tostring(k) .. "=" .. tostring(t[k]) end
  return "{" .. table.concat(out, " ") .. "}"
end
local function three() return 7, 8, 9 end

for i = 1, 3 do
  local half = i / 2
  print(dump({x = i, y = nil, z = i * 2}),
        dump({a = 1, a = 2, b = i}),
        dump({["k"] = i, k2 = i, [i] = "pos?"}),
        dump({10, 20, name = "n" .. i, 30, flag = i > 1}),
        dump({first = i, three()}),
        dump({f = half, g = half + 0.25, h = "s"}),
        dump({}))
end

-- two sites with the same layout, then each grows differently
local function mk1(v) return {p = v, q = v + 1} end
local function mk2(v) return {p = v * 10, q = v * 10 + 1} end
local r1, r2, r3 = mk1(1), mk2(2), mk1(3)
r1.extra = "e"; r2.q = nil; r3.p = nil; r3.p = "back"
print(dump(r1), dump(r2), dump(r3), dump(mk1(5)))

-- built empty and filled versus constructed
local inc = {}
inc.p = 4; inc.q = 5
local lit = {p = 4, q = 5}
inc.p = nil; lit.q = nil
print(dump(inc), dump(lit))

-- a wide record, then more fields than a record holds
local wide = {f1 = 1, f2 = 2, f3 = 3, f4 = 4, f5 = 5, f6 = 6, f7 = 7, f8 = 8, f9 = 9, f10 = 10,
              f11 = 11, f12 = 12, f13 = 13, f14 = 14, f15 = 15, f16 = 16, f17 = 17, f18 = 18}
for i = 19, 50 do wide["f" .. i] = i end
local s = 0
for _, v in pairs(wide) do s = s + v end
print("wide", s, wide.f1, wide.f18, wide.f50)

-- float fields updated in place, unboxed
local p = {x = 0.5, y = 1.5}
for _ = 1, 4 do p.x = p.x * 2; p.y = p.y + p.x end
print(dump(p), math.type(p.x))

-- constructors as metatables and objects
local Mt = {__index = function(t, k) return "dflt:" .. k end}
local o = setmetatable({known = 1}, Mt)
print(o.known, o.unknown, rawget(o, "unknown"))
