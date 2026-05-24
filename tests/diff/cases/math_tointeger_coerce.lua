-- math.tointeger coerces a numeric-string argument (like the other math.*
-- functions / the README note), returning the integer or fail. Fuzzer-found:
-- math.tointeger("42") was nil instead of 42.
print(math.tointeger("42"))
print(math.tointeger("9223372036854775807"))
print(math.tointeger("0x10"))
print(math.tointeger("2.0"))
print(math.tointeger("1.5"))
print(math.tointeger("abc"))
print(math.tointeger(3.0))
print(math.tointeger(3.5))
print(math.tointeger(7))
