-- nbody with bodies as integer-indexed arrays instead of named fields.
-- Diagnostic twin of nbody.lua: the delta between the two is the cost of the
-- string-key table path (hashing, key compare) versus the array part.
local sqrt = math.sqrt
local PI = math.pi
local SOLAR_MASS = 4 * PI * PI
local DAYS_PER_YEAR = 365.24
local bodies = {
  {0,0,0,0,0,0,SOLAR_MASS},
  {4.84143144246472090e+00,-1.16032004402742839e+00,-1.03622044471123109e-01,1.66007664274403694e-03*DAYS_PER_YEAR,7.69901118419740425e-03*DAYS_PER_YEAR,-6.90460016972063023e-05*DAYS_PER_YEAR,9.54791938424326609e-04*SOLAR_MASS},
  {8.34336671824457987e+00,4.12479856412430479e+00,-4.03523417114321381e-01,-2.76742510726862411e-03*DAYS_PER_YEAR,4.99852801234917238e-03*DAYS_PER_YEAR,2.30417297573763929e-05*DAYS_PER_YEAR,2.85885980666130812e-04*SOLAR_MASS},
  {1.28943695621391310e+01,-1.51111514016986312e+01,-2.23307578892655734e-01,2.96460137564761618e-03*DAYS_PER_YEAR,2.37847173959480950e-03*DAYS_PER_YEAR,-2.96589568540237556e-05*DAYS_PER_YEAR,4.36624404335156298e-05*SOLAR_MASS},
  {1.53796971148509165e+01,-2.59193146099879641e+01,1.79258772950371181e-01,2.68067772490389322e-03*DAYS_PER_YEAR,1.62824170038242295e-03*DAYS_PER_YEAR,-9.51592254519715870e-05*DAYS_PER_YEAR,5.15138902046611451e-05*SOLAR_MASS},
}
local function advance(bodies, nbody, dt)
  for i=1,nbody do
    local bi = bodies[i]
    local bix, biy, biz, bimass = bi[1], bi[2], bi[3], bi[7]
    local bivx, bivy, bivz = bi[4], bi[5], bi[6]
    for j=i+1,nbody do
      local bj = bodies[j]
      local dx, dy, dz = bix-bj[1], biy-bj[2], biz-bj[3]
      local dist2 = dx*dx + dy*dy + dz*dz
      local mag = sqrt(dist2)
      mag = dt / (mag * dist2)
      local bm = bj[7]*mag
      bivx = bivx - (dx * bm)
      bivy = bivy - (dy * bm)
      bivz = bivz - (dz * bm)
      bm = bimass*mag
      bj[4] = bj[4] + (dx * bm)
      bj[5] = bj[5] + (dy * bm)
      bj[6] = bj[6] + (dz * bm)
    end
    bi[4] = bivx
    bi[5] = bivy
    bi[6] = bivz
    bi[1] = bix + dt * bivx
    bi[2] = biy + dt * bivy
    bi[3] = biz + dt * bivz
  end
end
local function energy(bodies, nbody)
  local e = 0
  for i=1,nbody do
    local bi = bodies[i]
    local vx, vy, vz, bim = bi[4], bi[5], bi[6], bi[7]
    e = e + (0.5 * bim * (vx*vx + vy*vy + vz*vz))
    for j=i+1,nbody do
      local bj = bodies[j]
      local dx, dy, dz = bi[1]-bj[1], bi[2]-bj[2], bi[3]-bj[3]
      local distance = sqrt(dx*dx + dy*dy + dz*dz)
      e = e - ((bim * bj[7]) / distance)
    end
  end
  return e
end
local function offsetMomentum(b, nbody)
  local px, py, pz = 0, 0, 0
  for i=1,nbody do
    local bi = b[i]
    local bim = bi[7]
    px = px + (bi[4] * bim)
    py = py + (bi[5] * bim)
    pz = pz + (bi[6] * bim)
  end
  b[1][4] = -px / SOLAR_MASS
  b[1][5] = -py / SOLAR_MASS
  b[1][6] = -pz / SOLAR_MASS
end
local N = 500000
local nbody = #bodies
local t0 = os.clock()
offsetMomentum(bodies, nbody)
io.write( string.format("%0.9f",energy(bodies, nbody)), "\n")
for i=1,N do advance(bodies, nbody, 0.01) end
io.write( string.format("%0.9f",energy(bodies, nbody)), "\n")
io.write(string.format("TIME %.3f\n", os.clock()-t0))
