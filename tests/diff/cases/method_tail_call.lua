-- A method call in tail position (`return self:m(...)`) must be a proper
-- tail call running in constant stack, exactly like `return f(...)`.
-- Without TCO this depth overflows the host stack; reference Lua completes
-- it. (Pre-fix, only the regular-call form was tail-call optimized.)
local Counter = {}
Counter.__index = Counter
function Counter.new() return setmetatable({n = 0}, Counter) end
function Counter:bump(k)
  self.n = self.n + 1
  if k == 0 then return self.n end
  return self:bump(k - 1)            -- tail method call
end
print(Counter.new():bump(1000000))  -- 1000001

-- Tail method call resolved through __index inheritance.
local Base = {}; Base.__index = Base
function Base:loop(k) if k == 0 then return "ok" end return self:loop(k - 1) end
local Derived = setmetatable({}, Base); Derived.__index = Derived
print(setmetatable({}, Derived):loop(1000000))   -- ok
