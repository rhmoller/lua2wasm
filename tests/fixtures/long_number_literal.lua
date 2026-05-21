-- Numeric literals longer than the lexer's internal stack buffer (>63 bytes)
-- must be parsed in full, not silently truncated. A long integer with many
-- leading zeros only yields the right value if the trailing significant digits
-- survive; an old fixed `char tmp[64]` truncated them and produced 0.
print(00000000000000000000000000000000000000000000000000000000000000000123)
-- A long float must likewise round to the real value, not the truncated prefix.
print(1.0000000000000000000000000000000000000000000000000000000000000000000005)
-- Long `.frac` form (no leading integer part) goes through a separate path.
print(.50000000000000000000000000000000000000000000000000000000000000000000001)
