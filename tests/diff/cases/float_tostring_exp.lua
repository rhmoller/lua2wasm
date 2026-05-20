-- BUG: a float already in exponent form gets a spurious ".0" appended (the
-- integer-looking check tests for '.' but not 'e'). Reference: "1e+100"
print(tostring(1e100))
print(1e100)
