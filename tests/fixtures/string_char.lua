-- string.char(...) — string built from byte values, each in [0, 255].

print(string.char(65, 66, 67))        -- ABC
print(string.char(72, 105, 33))       -- Hi!
print(string.char())                  -- (empty string)
print(#string.char(0, 1, 2))          -- 3       (length, content unprintable)
print(#string.char(255))              -- 1       (byte 0xFF, non-UTF-8)

-- byte / char round-trip.
print(string.char(string.byte("X")))            -- X
print(string.char(string.byte("ABC", 1, 3)))    -- ABC

-- Out-of-range values raise.
local ok1 = pcall(function() return string.char(-1) end)
print(ok1)                            -- false
local ok2 = pcall(function() return string.char(256) end)
print(ok2)                            -- false

-- Length matches arg count.
print(#string.char(1, 2, 3, 4, 5))    -- 5
