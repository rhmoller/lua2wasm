-- integral-float keys normalize to integer (observable via pairs/math.type)
local t = {}
t[3.0] = "a"
for k, v in pairs(t) do print("k1", math.type(k), k, v) end
-- t[3.0] and t[3] are the same slot
t[3] = "b"
local n = 0
for _ in pairs(t) do n = n + 1 end
print("count", n, "t[3.0]=", t[3.0])
-- non-integral float stays a float key
local u = {}
u[1.5] = "x"
for k in pairs(u) do print("k2", math.type(k)) end
-- float beyond integer range stays a float key
local w = {}
w[2.0^63] = "y"
for k in pairs(w) do print("k3", math.type(k)) end
-- key normalization through the array-part fast path too
local a = {}
a[1.0] = 10
print("k4", math.type((next(a))))
