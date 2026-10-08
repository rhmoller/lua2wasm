-- Particle system in the "structure of arrays" style performance-minded
-- Love2D code uses: parallel numeric arrays indexed by particle id, a free
-- list pool, emitters, gravity/drag integration, lifetime kill, and a
-- per-frame sort of a subset by depth. Numeric-array heavy.
local seed = 777
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end
local function frand(lo, hi) return lo + (rnd() % 10000) / 10000 * (hi - lo) end

local MAX = 20000
local px, py, vx, vy, life, size, kind = {}, {}, {}, {}, {}, {}, {}
local free, nfree = {}, 0
local alive, nalive = {}, 0
for i = 1, MAX do px[i], py[i], vx[i], vy[i], life[i], size[i], kind[i] = 0, 0, 0, 0, 0, 1, 1 end
for i = MAX, 1, -1 do nfree = nfree + 1; free[nfree] = i end

local function emit(x, y, n, k)
  for _ = 1, n do
    if nfree == 0 then return end
    local id = free[nfree]; nfree = nfree - 1
    px[id], py[id] = x, y
    local a, s = frand(0, 6.283185), frand(20, 120)
    vx[id], vy[id] = math.cos(a) * s, math.sin(a) * s
    life[id] = frand(0.5, 2.5)
    size[id] = frand(1, 4)
    kind[id] = k
    nalive = nalive + 1; alive[nalive] = id
  end
end

local gravity, drag = 98, 0.98
local dt = 1 / 60
local t0 = os.clock()
local worst, sum_ft = 0, 0
local depth = {}
for frame = 1, 900 do
  local f0 = os.clock()
  emit(400 + math.sin(frame * 0.05) * 200, 300, 150, 1 + frame % 3)
  local w = 0
  for i = 1, nalive do
    local id = alive[i]
    local l = life[id] - dt
    if l > 0 then
      life[id] = l
      local vyy = (vy[id] + gravity * dt) * drag
      local vxx = vx[id] * drag
      local x, y = px[id] + vxx * dt, py[id] + vyy * dt
      if y > 600 then y = 600; vyy = -vyy * 0.6 end
      if x < 0 or x > 800 then vxx = -vxx end
      px[id], py[id], vx[id], vy[id] = x, y, vxx, vyy
      w = w + 1; alive[w] = id
    else
      nfree = nfree + 1; free[nfree] = id
    end
  end
  for i = w + 1, nalive do alive[i] = nil end
  nalive = w
  -- depth-sort the first few hundred for "draw order"
  local n = nalive < 300 and nalive or 300
  for i = 1, n do depth[i] = alive[i] end
  for i = n + 1, #depth do depth[i] = nil end
  table.sort(depth, function(a, b) return py[a] < py[b] end)
  local ft = os.clock() - f0
  sum_ft = sum_ft + ft
  if ft > worst then worst = ft end
end
local cx, cy, cs = 0, 0, 0
for i = 1, nalive do local id = alive[i]; cx = cx + px[id]; cy = cy + py[id]; cs = cs + size[id] * kind[id] end
print(string.format("alive=%d free=%d", nalive, nfree))
print(string.format("checksum %.3f %.3f %.3f %d", cx, cy, cs, depth[1] or 0))
print(string.format("TIME_FRAME_AVG_MS %.3f", sum_ft / 900 * 1000))
print(string.format("TIME_FRAME_MAX_MS %.3f", worst * 1000))
print(string.format("TIME %.3f", os.clock() - t0))
