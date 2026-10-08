-- Vector-math library idiom: an immutable Vec3 class with operator
-- metamethods, method chains creating temporaries, dot/cross/lerp, a
-- transform pipeline over many points, and a bounding-sphere pass. Exercises
-- metamethod dispatch and per-operation table allocation.
local Vec3 = {}
Vec3.__index = Vec3
local function v3(x, y, z) return setmetatable({x = x, y = y, z = z}, Vec3) end
Vec3.__add = function(a, b) return v3(a.x + b.x, a.y + b.y, a.z + b.z) end
Vec3.__sub = function(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
Vec3.__mul = function(a, s) if type(a) == "number" then return v3(a * s.x, a * s.y, a * s.z) end return v3(a.x * s, a.y * s, a.z * s) end
Vec3.__unm = function(a) return v3(-a.x, -a.y, -a.z) end
Vec3.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function Vec3:dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function Vec3:cross(b) return v3(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end
function Vec3:len() return math.sqrt(self:dot(self)) end
function Vec3:normalized() local l = self:len(); return v3(self.x / l, self.y / l, self.z / l) end
function Vec3:lerp(b, t) return self + (b - self) * t end

local seed = 99
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end
local function frand(lo, hi) return lo + (rnd() % 10000) / 10000 * (hi - lo) end

local points = {}
for i = 1, 5000 do points[i] = v3(frand(-10, 10), frand(-10, 10), frand(-10, 10)) end
local axis = v3(0.3, 0.9, 0.1):normalized()

local t0 = os.clock()
local acc = v3(0, 0, 0)
local maxr = 0
for frame = 1, 120 do
  local angle = frame * 0.01
  local c, s = math.cos(angle), math.sin(angle)
  local center = v3(0, 0, 0)
  for i = 1, #points do
    local p = points[i]
    -- Rodrigues rotation about axis
    local rotated = p * c + axis:cross(p) * s + axis * (axis:dot(p) * (1 - c))
    local moved = rotated:lerp(p, 0.5) + v3(0.01, 0, 0)
    points[i] = moved
    center = center + moved
  end
  center = center * (1 / #points)
  for i = 1, #points do
    local r = (points[i] - center):len()
    if r > maxr then maxr = r end
  end
  acc = acc + center
end
print(string.format("checksum %.4f %.4f %.4f %.4f", acc.x, acc.y, acc.z, maxr))
print(string.format("TIME %.3f", os.clock() - t0))
