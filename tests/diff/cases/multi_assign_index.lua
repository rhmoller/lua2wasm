-- Multi-target assignment with index targets. Every target's table and key
-- is evaluated (left to right) before any value, all values before any store;
-- stores then run right to left, so a repeated target keeps its leftmost
-- value. Keys are snapshotted: assigning the key variable in the same
-- statement doesn't move the store. Covers captured tables (the boxed-upvalue
-- case), maybe-typed keys, float values that go to unboxed storage, and
-- __newindex ordering.
local px, py, vx, vy = {}, {}, {}, {}
local function reset() for i = 1, 4 do px[i], py[i], vx[i], vy[i] = 0, 0, 0, 0 end end
reset()
local ids = {3, 1, 2.0}
for n = 1, #ids do
  local id = ids[n]
  local x, y = px[id] + 0.5 * n, py[id] - n
  px[id], py[id], vx[id], vy[id] = x, y, x * y, n
end
print(table.concat(px, " "), table.concat(py, " "), table.concat(vx, " "), table.concat(vy, " "))
print(math.type(px[3]), math.type(vy[3]), #px)

-- keys snapshotted before the stores; leftmost repeated target wins
local t, i = {}, 1
t[i], i = "a", 2
print(t[1], t[2], i)
i, t[i] = 3, "b"
print(t[2], t[3], i)
local g = {}
g.a, g.b, g.a = 1, 2, 3
print(g.a, g.b)
local r = {}
r[1], r[1.0], r[2] = "x", "y", "z"
print(r[1], r[2], #r)

-- evaluation order: tables and keys first, then values (the manual leaves
-- this undefined; reference Lua and lua2wasm both do it left to right)
local log = {}
local function T(tag, tbl) log[#log + 1] = tag; return tbl end
local function V(tag, v) log[#log + 1] = tag; return v end
local a, b = {}, {}
T("ta", a)[V("ka", 1)], T("tb", b)[V("kb", "k")] = V("va", 10), V("vb", 20)
print(table.concat(log, ","), a[1], b.k)

-- __newindex fires right to left for absent keys
local seen = {}
local mt = {__newindex = function(tb, k, v) seen[#seen + 1] = tostring(k) .. "=" .. tostring(v); rawset(tb, k, v) end}
local p, q = setmetatable({}, mt), setmetatable({}, mt)
p[1], q.x, p[2] = 1.5, "s", 2 * 1.25
print(table.concat(seen, " "), p[1], q.x, p[2])

-- mixed var and index targets, swaps, and a call adjusted to one value
local m = {10, 20, 30}
local j, k = 1, 3
m[j], m[k] = m[k], m[j]
print(table.concat(m, " "))
local function two() return 4, 5 end
local u, w
u, m[2], w = 1, two()
print(u, m[2], w)
m[1], m[2] = two()
print(m[1], m[2])

-- nil / NaN keys still raise from a multi-assignment
local nk
local ok0, err0 = pcall(function() m[1], m[nk] = 1, 2 end)
print(ok0, (err0:gsub("^.-:%d+: ", ""))) -- chunk-name formatting isn't asserted
local ok, err = pcall(function() local nan = 0 / 0; m[nan], m[1] = 1, 2 end)
print(ok, err and (err:find("NaN") ~= nil))
