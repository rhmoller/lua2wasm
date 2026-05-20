-- Number corners that already match reference Lua 5.5.
print(math.type(math.floor(3.7)), math.type(math.ceil(3.2)), math.floor(3.7), math.ceil(-2.1))
print(math.abs(math.mininteger), math.maxinteger // -1)
local t = {} t[2.0] = 10 print(t[2], t[2.0]) t[3] = 7 print(t[3.0])
print(math.maxinteger < math.maxinteger + 0.0, math.maxinteger + 0.0 == math.maxinteger)
print(math.tointeger(3.0), math.tointeger(3.5), math.tointeger(2 ^ 53))
print(4 / 2, math.type(4 / 2), 7 // 2, math.type(7 // 2))
print(math.huge, -math.huge, math.maxinteger, math.mininteger)
