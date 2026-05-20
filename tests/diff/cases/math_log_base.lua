-- BUG: Lua computes math.log(x, 10) via log10 and math.log(x, 2) via log2 for
-- exact results; lua2wasm does log(x)/log(base), losing a ULP. Reference: 3.0
print(math.log(1000, 10))
