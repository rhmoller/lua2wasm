local Animal = {kind = "animal"}
Animal.speak = function(self) return self.kind .. " speaks" end

local Dog = setmetatable({kind = "dog"}, {__index = Animal})
print(Dog.speak(Dog))

-- vector with __add
local Vec = {}
Vec.__add = function(a, b)
  return setmetatable({x = a.x + b.x, y = a.y + b.y}, Vec)
end
local v = setmetatable({x = 1, y = 2}, Vec) + setmetatable({x = 10, y = 20}, Vec)
print(v.x); print(v.y)
