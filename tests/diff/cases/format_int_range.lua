-- %d/%i/%c/%x... require an integer representation that fits in a Lua integer.
-- A float beyond ±2^63 has none and must raise, not be formatted as a giant
-- integer. Fuzzer-found: string.format("%d", 1e308) emitted a 300-digit number.
local function bad(...) local ok, e = pcall(string.format, ...); return ok, type(e) end
print(bad("%d", 1e308))
print(bad("%i", 1e308))
print(bad("%d", 1e19))            -- > 2^63
print(bad("%x", 2.0^63))          -- exactly 2^63, out of range
print(bad("%c", 1e308))
-- in-range integral floats and ints still format
print(string.format("%d", 2.0^62))   -- 4611686018427387904
print(string.format("%d", -2.0^63))  -- mininteger (in range)
print(string.format("%d", 42.0))
print(string.format("%x", 255))
