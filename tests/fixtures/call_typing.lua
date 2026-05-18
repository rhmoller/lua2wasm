-- Calling a non-callable now throws a Lua-shaped error (catchable by
-- pcall) instead of trapping the wasm engine with a generic ref.cast.
local ok1, msg1 = pcall(function() local x = nil; x() end)
print(ok1)
print(msg1)

local ok2, msg2 = pcall(function() local x = 42; x() end)
print(ok2)
print(msg2)

-- `__call` makes a table behave like a function. Calling it should
-- recursively dispatch and the receiver should be prepended to args.
local Callable = setmetatable({tag = "obj"}, {
  __call = function(self, a, b)
    return self.tag, a + b
  end,
})
local t, sum = Callable(10, 20)
print(t)
print(sum)

-- Chained __call: Outer's __call is itself a table whose __call is a
-- function. Each hop prepends the current callee, so the function sees
-- (Inner, Outer) before the user's args — matching reference Lua.
local Inner = setmetatable({}, {
  __call = function(self_inner, self_outer)
    return "via:" .. tostring(self_inner == self_outer)
  end,
})
local Outer = setmetatable({}, { __call = Inner })
print(Outer())
