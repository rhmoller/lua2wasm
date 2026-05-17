-- `:` method-call and method-definition sugar.

local T = {greeting = "hi"}

-- Method definition: function T:m(a) end == T.m = function(self, a) end
function T:greet(name)
  return self.greeting .. ", " .. name
end

-- Method call: T:greet(x) == T.greet(T, x)
print(T:greet("world"))      -- "hi, world"

-- Inherited via __index, with method call
local Sub = setmetatable({greeting = "yo"}, {__index = T})
print(Sub:greet("there"))    -- "yo, there"

-- Multiple args
function T:add(a, b)
  return self.greeting, a + b
end
local g, n = T:add(2, 3)
print(g)                     -- "hi"
print(n)                     -- 5
