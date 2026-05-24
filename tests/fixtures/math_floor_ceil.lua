-- math.floor/ceil must not trap on out-of-i64-range floats: they return an
-- integer only when the result fits, otherwise the float unchanged.
print(math.floor(1e30))
print(math.ceil(1e30))
print(math.floor(3.7), math.floor(-3.2))
print(math.ceil(3.2), math.ceil(-3.7))
print(math.type(math.floor(3.0)), math.type(math.floor(1e30)))
print(math.floor(math.huge), math.ceil(-math.huge))
print(math.floor(9223372036854775807.0))
print(math.type(math.floor(0/0)))         -- nan stays a float (no trap)
print(pcall(math.floor, 1e30))            -- true (catchable, but no error)
