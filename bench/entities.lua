-- Game-logic shape: an entity system with class-style metatables, named
-- fields updated every frame through methods, a string-keyed state machine,
-- per-frame vector temporaries, spawn/despawn churn on lists, timers as
-- closures, and a simple AABB collision pass. Deterministic (LCG); prints a
-- checksum and per-frame timing stats (TIME_* lines are excluded from output
-- comparison by scripts/bench.sh).

local seed = 12345
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end
local function frand(lo, hi) return lo + (rnd() % 10000) / 10000 * (hi - lo) end

-- immutable 2D vectors, the Love2D/hump idiom
local Vec = {}
Vec.__index = Vec
local function vec(x, y) return setmetatable({x = x, y = y}, Vec) end
Vec.__add = function(a, b) return vec(a.x + b.x, a.y + b.y) end
Vec.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y) end
Vec.__mul = function(a, s) return vec(a.x * s, a.y * s) end
function Vec:len() return math.sqrt(self.x * self.x + self.y * self.y) end
function Vec:normalized() local l = self:len(); if l > 0 then return vec(self.x / l, self.y / l) end return vec(0, 0) end

-- base class
local Entity = {}
Entity.__index = Entity
function Entity.new(x, y)
  return setmetatable({pos = vec(x, y), vel = vec(0, 0), hp = 100, state = "idle",
                       w = 8, h = 8, age = 0, alive = true, timer = nil}, Entity)
end
function Entity:update(dt)
  self.age = self.age + dt
  self.pos = self.pos + self.vel * dt
  if self.pos.x < 0 or self.pos.x > 800 then self.vel = vec(-self.vel.x, self.vel.y) end
  if self.pos.y < 0 or self.pos.y > 600 then self.vel = vec(self.vel.x, -self.vel.y) end
  if self.timer then self.timer(dt) end
end
function Entity:aabb(o)
  return math.abs(self.pos.x - o.pos.x) * 2 < (self.w + o.w) and math.abs(self.pos.y - o.pos.y) * 2 < (self.h + o.h)
end

-- subclass with a state machine
local Enemy = setmetatable({}, {__index = Entity})
Enemy.__index = Enemy
function Enemy.new(x, y)
  local e = Entity.new(x, y)
  e.vel = vec(frand(-60, 60), frand(-60, 60))
  e.cooldown = frand(0.5, 2.0)
  return setmetatable(e, Enemy)
end
function Enemy:update(dt, player)
  Entity.update(self, dt)
  local st = self.state
  if st == "idle" then
    if (player.pos - self.pos):len() < 150 then self.state = "chase" end
  elseif st == "chase" then
    local dir = (player.pos - self.pos):normalized()
    self.vel = dir * 90
    self.cooldown = self.cooldown - dt
    if self.cooldown <= 0 then self.state = "attack"; self.cooldown = 1.5 end
    if (player.pos - self.pos):len() > 250 then self.state = "idle" end
  elseif st == "attack" then
    self.cooldown = self.cooldown - dt
    if self.cooldown <= 0 then self.state = "chase"; self.cooldown = frand(0.5, 2.0) end
  end
end

local Bullet = setmetatable({}, {__index = Entity})
Bullet.__index = Bullet
function Bullet.new(x, y, dir)
  local b = Entity.new(x, y)
  b.vel = dir * 300
  b.w, b.h = 2, 2
  b.ttl = 2.0
  return setmetatable(b, Bullet)
end
function Bullet:update(dt)
  Entity.update(self, dt)
  self.ttl = self.ttl - dt
  if self.ttl <= 0 then self.alive = false end
end

local player = Entity.new(400, 300)
player.vel = vec(30, 20)
local enemies, bullets = {}, {}
for i = 1, 600 do enemies[i] = Enemy.new(frand(0, 800), frand(0, 600)) end
local spawned, killed, hits = 0, 0, 0

local function spawn_wave(n)
  for _ = 1, n do
    local e = Enemy.new(frand(0, 800), frand(0, 600))
    local ticks = 0
    e.timer = function(dt) ticks = ticks + 1; if ticks % 60 == 0 then e.hp = e.hp - 1 end end
    enemies[#enemies + 1] = e
    spawned = spawned + 1
  end
end

local dt = 1 / 60
local frames = 1500
local t0 = os.clock()
local worst, sum_ft = 0, 0
for frame = 1, frames do
  local f0 = os.clock()
  player:update(dt)
  for i = 1, #enemies do enemies[i]:update(dt, player) end
  for i = 1, #bullets do bullets[i]:update(dt) end
  -- fire at the nearest enemy every 4 frames
  if frame % 4 == 0 and #enemies > 0 then
    local best, bd = nil, 1e9
    for i = 1, #enemies do
      local d = (enemies[i].pos - player.pos):len()
      if d < bd then bd, best = d, enemies[i] end
    end
    bullets[#bullets + 1] = Bullet.new(player.pos.x, player.pos.y, (best.pos - player.pos):normalized())
  end
  -- collisions: bullets vs enemies (brute force, like small games do)
  for bi = 1, #bullets do
    local b = bullets[bi]
    if b.alive then
      for ei = 1, #enemies do
        local e = enemies[ei]
        if e.alive and b:aabb(e) then
          e.hp = e.hp - 34; b.alive = false; hits = hits + 1
          if e.hp <= 0 then e.alive = false end
          break
        end
      end
    end
  end
  -- despawn (swap-remove keeps order irrelevant, like most engines)
  for i = #enemies, 1, -1 do
    if not enemies[i].alive then enemies[i] = enemies[#enemies]; enemies[#enemies] = nil; killed = killed + 1 end
  end
  for i = #bullets, 1, -1 do
    if not bullets[i].alive then bullets[i] = bullets[#bullets]; bullets[#bullets] = nil end
  end
  if frame % 90 == 0 then spawn_wave(25) end
  local ft = os.clock() - f0
  sum_ft = sum_ft + ft
  if ft > worst then worst = ft end
end
local sx, sy, ages = 0, 0, 0
for i = 1, #enemies do local e = enemies[i]; sx = sx + e.pos.x; sy = sy + e.pos.y; ages = ages + e.age end
print(string.format("enemies=%d bullets=%d spawned=%d killed=%d hits=%d", #enemies, #bullets, spawned, killed, hits))
print(string.format("checksum %.3f %.3f %.3f %.3f", sx, sy, ages, player.pos.x + player.pos.y))
print(string.format("TIME_FRAME_AVG_MS %.3f", sum_ft / frames * 1000))
print(string.format("TIME_FRAME_MAX_MS %.3f", worst * 1000))
print(string.format("TIME %.3f", os.clock() - t0))
