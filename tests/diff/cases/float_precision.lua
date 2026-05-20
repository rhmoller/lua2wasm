-- BUG: floats print with ~14 significant digits, losing round-trip precision.
-- Lua 5.5 prints enough digits to round-trip. Reference: "1.4142135623730951"
print(2^0.5)
print(0.1 + 0.2)
