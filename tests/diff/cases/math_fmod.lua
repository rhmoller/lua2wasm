-- math.fmod: truncated remainder. Integer args give an integer result; float
-- args must use a precise fmod (x - trunc(x/y)*y catastrophically cancels for
-- large magnitudes). Fuzzer-found: fmod(1e308, 255) was 0.0, should be 101.0.
print(math.fmod(1e308, 255))
print(math.fmod(10, 3))
print(math.fmod(10.0, 3.0))
print(math.fmod(-10.5, 3))
print(math.fmod(1e15, 7))
print(math.fmod(5.5, 2))
print(math.fmod(-7, 3))
print(math.fmod(123456789012.0, 1000.0))
