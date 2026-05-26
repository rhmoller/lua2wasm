-- A "Stack" class — exercises tables, metatables, OO sugar, closures,
-- errors, and pcall in one short program.

local Stack = {}                        -- a Lua table → a `$LuaTable` struct:
Stack.__index = Stack                   --   array part + open-addressed hash + `meta` slot

function Stack.new()
  return setmetatable({n = 0}, Stack)   -- writes Stack into the struct's `meta` field
end                                     -- `Stack.new` itself is a `(ref $LuaClosure)` =
                                        --   struct (funcref code, upvalue array)

function Stack:push(v)                  -- `:` desugars to `self` as the first parameter
  self.n = self.n + 1                   -- small ints unbox to `i31ref` — zero allocation
  self[self.n] = v                      -- integer keys land in the dense array part
end

function Stack:pop()
  if self.n == 0 then
    error("stack underflow")            -- compiles to `throw $LuaError` (anyref payload)
  end
  local v, n = self[self.n], self.n
  self[n], self.n = nil, n - 1
  return v
end

local s = Stack.new()
s:push("hi"); s:push("from"); s:push("lua2wasm")
-- each string literal materialises once via `array.new_data` from a shared data segment

for i = 1, s.n do print(s[i]) end       -- numeric `for` keeps `i` as a raw `i64`;
                                        -- the call to `print` dispatches via `call_ref`

local ok, err = pcall(function()        -- `pcall` → `try_table (catch $LuaError ...)`
  for _ = 1, 4 do s:pop() end           -- the 4th `pop` underflows and throws
end)
print(ok, err)                          --> false   <src>:19: stack underflow
