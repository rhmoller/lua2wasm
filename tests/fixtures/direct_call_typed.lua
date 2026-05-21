-- Param + return unboxing for statically-bound local-function calls
-- (LUA2WASM_OPT_INT). Behaviour must be identical with the flag on or off and
-- must match reference Lua: the optimization only changes the emitted WAT.

-- 1. canonical hot int helper: int param in, int return out, called in a loop
local function add1(x) return x + 1 end
local s = 0
for i = 1, 10 do s = s + add1(i) end
print(s)                          -- 65

-- 2. multi-parameter int helper
local function muladd(a, b, c) return a * b + c end
print(muladd(3, 4, 5))            -- 17

-- 3. helper used in multi-value (argument) context
local function dbl(n) return n * 2 end
print(dbl(21), dbl(10))           -- 42	20

-- 4. polymorphic call sites (int, string, float) force a boxed fallback
local function id(v) return v end
print(id(7), id("hi"), id(3.5))   -- 7	hi	3.5

-- 5. a reassigned parameter must not be unboxed
local function clamp(x)
  if x < 0 then x = 0 end
  return x
end
print(clamp(-4), clamp(9))        -- 0	9

-- 6. chained / nested direct calls: return-type propagation across functions
local function inc(x) return x + 1 end
local function inc2(x) return inc(inc(x)) end
print(inc2(40))                   -- 42

-- 7. float param/return helper (division is always float)
local function half(x) return x / 2 end
print(half(9))                    -- 4.5

-- 8. parameter used as a string: return type is generic, args fall back
local function shout(t) return t .. "!" end
print(shout("hey"))               -- hey!

-- 9. mixed numeric: int argument flowing into a float-typed body
local function scale(x) return x * 1.5 end
print(scale(4))                   -- 6.0

-- 10. function called both directly (specialized) and as a value (generic)
local function sq(x) return x * x end
local apply = function(fn, v) return fn(v) end
print(sq(8), apply(sq, 9))        -- 64	81

-- 11. a function that may fall through (not always-return) keeps a boxed return
local function maybe(x)
  if x > 0 then return x * 10 end
end
print(maybe(5), maybe(-1))        -- 50	nil

-- 12. early return + final return, both int (always-returns through if/else)
local function sign(x)
  if x < 0 then return -1 else return 1 end
end
print(sign(-8), sign(8))          -- -1	1
