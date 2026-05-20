-- Regression anchor: integer/float arithmetic that already matches reference.
print(10 // 3, 2 ^ 10, 7 % 3, -7 % 3, 5.5 % 2)
print(math.maxinteger + 1 == math.mininteger)
print(1 << 62, ~0, 0xff & 0x0f, 5 ~ 3)
print(3 == 3.0, math.type(3), math.type(3.0))
