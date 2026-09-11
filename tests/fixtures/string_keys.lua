-- Constant string keys are hoisted into module globals (one object per
-- distinct literal, hash precomputed) and every string caches its hash. The
-- lookups below mix constant keys, runtime-built keys with the same bytes,
-- keys too long to hoist, metatable chains and deletion, and must all agree
-- with reference Lua.

local t = {x = 1, ["y z"] = 2, [""] = 3, ["1"] = "str-one", [1] = "int-one"}
print(t.x, t["x"], t["y z"], t[""], t["1"], t[1])

-- runtime-built keys with the same bytes as a constant
local kx = "x" .. ""
local kyz = "y" .. " " .. "z"
print(t[kx], t[kyz], kx == "x", "ab" == "a" .. "b", "ab" == "ba")
t[kx] = 10
print(t.x, t[kx])

-- long keys stay in the data segment and go through the byte compare
local long = string.rep("k", 300)
t[long] = "long"
print(t[string.rep("k", 300)], #long, t[string.rep("k", 299)])

-- delete then re-add via the constant-key setter
t.x = nil
print(t.x, t[kx])
t.x = 42
print(t.x)

-- same-length strings must not collide, hash or not
local a, b = "abc", "abd"
local u = {}
u[a] = 1; u[b] = 2; u.abc = u.abc + 10
print(u.abc, u.abd, u["ab" .. "c"], u["ab" .. "d"], u.abe)

-- metatable chain: instance -> class -> base, with method calls
local Base = {}
Base.__index = Base
function Base.new(name) return setmetatable({name = name}, Base) end
function Base:hello() return "hello " .. self.name end
local Derived = setmetatable({}, {__index = Base})
Derived.__index = Derived
function Derived.new(name) local o = Base.new(name) return setmetatable(o, Derived) end
function Derived:shout() return self:hello():upper() end
local d = Derived.new("kim")
print(d:hello(), d:shout(), d.name, d.missing, rawget(d, "hello"))

-- __index function and __newindex with constant keys
local log = {}
local proxy = setmetatable({}, {
  __index = function(_, k) log[#log + 1] = "get " .. k; return k .. "!" end,
  __newindex = function(_, k, v) log[#log + 1] = "set " .. k .. "=" .. tostring(v) end,
})
print(proxy.foo, proxy["bar"])
proxy.baz = 5
proxy.baz = nil
print(table.concat(log, ", "))

-- metamethod names spelled at runtime resolve like the constants
local mt = {}
mt["__" .. "index"] = {dyn = "via runtime __index"}
local o = setmetatable({}, mt)
print(o.dyn, getmetatable(o).__index.dyn)

-- string library access through the string metatable
local s = "Hello"
print(s:len(), type(s.len), ("x"):rep(3), s:sub(2, 3))

-- iteration order over a small string-keyed table is stable across
-- constant and runtime keys (collect and sort for a deterministic print)
local m = {}
for i = 1, 20 do m["key" .. i] = i end
m.key5 = 500
local keys = {}
for k, v in pairs(m) do keys[#keys + 1] = k .. "=" .. v end
table.sort(keys)
print(#keys, keys[1], keys[#keys], m.key5, m["key" .. 5])

-- globals are string keys in _G
GLOBAL_A = "ga"
print(_G.GLOBAL_A, _G["GLOBAL_A"], rawget(_G, "GLOBAL_A"))
