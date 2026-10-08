-- Tile-map logic: a 2D grid of tables (grid[y][x] with named fields), A*
-- pathfinding with a binary heap and string-keyed visited sets, flood fill,
-- and a "camera cull" pass over the visible window. Mixed int-key grid
-- access, small records, and hash tables keyed by packed strings.
local W, H = 160, 120
local seed = 4242
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end

local grid = {}
for y = 1, H do
  local row = {}
  for x = 1, W do
    local r = rnd() % 100
    row[x] = {solid = r < 18, cost = 1 + (r % 5), kind = r < 18 and "wall" or (r < 30 and "grass" or "floor"), seen = 0}
  end
  grid[y] = row
end
-- guarantee a corridor
for x = 1, W do grid[math.floor(H / 2)][x].solid = false end
for y = 1, H do grid[y][math.floor(W / 2)].solid = false end

-- binary heap keyed on f
local function heap_push(h, node, f)
  local n = #h + 1
  h[n] = {node = node, f = f}
  while n > 1 do
    local p = math.floor(n / 2)
    if h[p].f <= h[n].f then break end
    h[p], h[n] = h[n], h[p]
    n = p
  end
end
local function heap_pop(h)
  local top = h[1]
  local last = h[#h]
  h[#h] = nil
  local n = #h
  if n > 0 then
    h[1] = last
    local i = 1
    while true do
      local l, r, s = 2 * i, 2 * i + 1, i
      if l <= n and h[l].f < h[s].f then s = l end
      if r <= n and h[r].f < h[s].f then s = r end
      if s == i then break end
      h[i], h[s] = h[s], h[i]
      i = s
    end
  end
  return top
end

local function key(x, y) return x .. "," .. y end
local function astar(sx, sy, tx, ty)
  local open = {}
  local g, closed = {}, {}
  local sk = key(sx, sy)
  g[sk] = 0
  heap_push(open, {x = sx, y = sy}, math.abs(tx - sx) + math.abs(ty - sy))
  local expanded = 0
  while #open > 0 do
    local cur = heap_pop(open).node
    local ck = key(cur.x, cur.y)
    if closed[ck] then goto continue end
    closed[ck] = true
    expanded = expanded + 1
    if cur.x == tx and cur.y == ty then return g[ck], expanded end
    for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
      local nx, ny = cur.x + d[1], cur.y + d[2]
      if nx >= 1 and nx <= W and ny >= 1 and ny <= H then
        local cell = grid[ny][nx]
        if not cell.solid then
          local nk = key(nx, ny)
          local ng = g[ck] + cell.cost
          if g[nk] == nil or ng < g[nk] then
            g[nk] = ng
            heap_push(open, {x = nx, y = ny}, ng + math.abs(tx - nx) + math.abs(ty - ny))
          end
        end
      end
    end
    ::continue::
  end
  return -1, expanded
end

local function flood(sx, sy, mark)
  local stack, n, count = {{sx, sy}}, 1, 0
  while n > 0 do
    local p = stack[n]; stack[n] = nil; n = n - 1
    local x, y = p[1], p[2]
    if x >= 1 and x <= W and y >= 1 and y <= H then
      local c = grid[y][x]
      if not c.solid and c.seen ~= mark then
        c.seen = mark; count = count + 1
        n = n + 1; stack[n] = {x + 1, y}
        n = n + 1; stack[n] = {x - 1, y}
        n = n + 1; stack[n] = {x, y + 1}
        n = n + 1; stack[n] = {x, y - 1}
      end
    end
  end
  return count
end

local t0 = os.clock()
local total_cost, total_exp, filled, visible = 0, 0, 0, 0
for i = 1, 40 do
  local sx, sy = 1 + rnd() % W, math.floor(H / 2)
  local tx, ty = math.floor(W / 2), 1 + rnd() % H
  local c, e = astar(sx, sy, tx, ty)
  total_cost = total_cost + c; total_exp = total_exp + e
end
for i = 1, 20 do filled = filled + flood(1 + rnd() % W, math.floor(H / 2), i) end
-- camera cull: count visible non-wall tiles for a moving 40x30 window
for f = 1, 300 do
  local cx, cy = 1 + (f * 3) % (W - 40), 1 + (f * 2) % (H - 30)
  for y = cy, cy + 29 do
    local row = grid[y]
    for x = cx, cx + 39 do
      local c = row[x]
      if c.kind ~= "wall" then visible = visible + 1 end
    end
  end
end
print(string.format("cost=%d expanded=%d filled=%d visible=%d", total_cost, total_exp, filled, visible))
print(string.format("TIME %.3f", os.clock() - t0))
