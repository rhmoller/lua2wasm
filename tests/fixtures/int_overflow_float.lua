-- A decimal integer literal / tonumber too big for a Lua integer becomes a
-- float; hex and explicit-base forms wrap instead (Lua 5.5 semantics).
print(math.type(9223372036854775807), 9223372036854775807)   -- integer (fits)
print(math.type(9223372036854775808), 9223372036854775808)   -- float (2^63)
print(math.type(99999999999999999999999999), 99999999999999999999999999)  -- float
print(math.type(0xffffffffffffffff), 0xffffffffffffffff)     -- integer -1 (hex wraps)
print(math.type(0x10000000000000000), 0x10000000000000000)   -- integer 0 (wraps)
print(math.type(tonumber("99999999999999999999999999")))     -- float
print(tonumber("99999999999999999999999999"))                -- 1e+26
print(math.type(tonumber("9223372036854775808")))            -- float
print(tonumber("99999999999999999999999999", 10))            -- wraps (integer)
print(tonumber("ffffffffffffffff", 16))                      -- -1 (wraps)
print(math.type(-9223372036854775808), -9223372036854775808) -- float? see ref
