-- class-style OO with metatable __index and method calls
local Vec = {}
Vec.__index = Vec
function Vec.new(x, y) return setmetatable({x = x, y = y}, Vec) end
function Vec:add(o) return Vec.new(self.x + o.x, self.y + o.y) end
function Vec:scale(k) self.x = self.x * k; self.y = self.y * k; return self end
function Vec:len2() return self.x * self.x + self.y * self.y end
Vec.__add = Vec.add

local Particle = {}
Particle.__index = Particle
function Particle.new(i)
  return setmetatable({pos = Vec.new(i, i * 0.5), vel = Vec.new(1, -1), id = i}, Particle)
end
function Particle:step(dt)
  self.pos = self.pos + self.vel:scale(1):scale(dt)
  if self.pos:len2() > 1e6 then self.vel:scale(-1) end
end

local t0 = os.clock()
local ps = {}
for i = 1, 1000 do ps[i] = Particle.new(i) end
local acc = 0
for step = 1, 2000 do
  for i = 1, #ps do
    local p = ps[i]
    p:step(0.01)
    acc = acc + p.pos.x
  end
end
io.write(string.format("%.3f\n", acc))
io.write(string.format("TIME %.3f\n", os.clock()-t0))
