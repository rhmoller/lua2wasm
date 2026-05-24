-- The '#' flag forces a decimal point for %f/%e even at precision 0 (and %g
-- keeps a trailing point). Fuzzer-found: %#.0f gave "5" instead of "5.".
print(string.format("%#.0f", 5))
print(string.format("%#.0f", -8))
print(string.format("%#.0f", 0))
print(string.format("%#.0e", 5))
print(string.format("%#.0E", 5))
print(string.format("%#.2f", 5))
print(string.format("%#g", 100000))
print(string.format("%#.3g", 256))
print(string.format("%.0f", 5))
