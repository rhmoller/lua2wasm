-- BUG: 1^inf is 1.0 per IEEE-754 (and reference Lua), but JS Math.pow(1, ∞)
-- is NaN, which the `^` host binding returns unchanged. Reference: 1.0
print(1 ^ math.huge)
