-- string.format("%d", <non-integer>) must raise a catchable error rather than
-- silently formatting 0. Integral floats and numeric strings still work.
-- Semantic check (a string error object); exact wording not asserted.
print(string.format("%d", 3.0), string.format("%d", "42"))
local ok, err = pcall(string.format, "%d", 3.5)
print(ok, type(err))
