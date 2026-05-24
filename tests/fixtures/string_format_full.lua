-- string.format — full Lua-5.5 spec coverage.

-- Width.
print("[" .. string.format("%10s", "hi") .. "]")     -- [        hi]
print("[" .. string.format("%-10s", "hi") .. "]")    -- [hi        ]
print("[" .. string.format("%5d", 42) .. "]")        -- [   42]
print("[" .. string.format("%-5d", 42) .. "]")       -- [42   ]
print("[" .. string.format("%05d", 42) .. "]")       -- [00042]
print("[" .. string.format("%05d", -42) .. "]")      -- [-0042]

-- Sign flags.
print(string.format("%+d", 5))                       -- +5
print(string.format("%+d", -5))                      -- -5
print(string.format("% d", 5))                       --  5
print(string.format("% d", -5))                      -- -5

-- Alt-form flag '#'.
print(string.format("%#x", 255))                     -- 0xff
print(string.format("%#X", 255))                     -- 0XFF
print(string.format("%#o", 8))                       -- 010

-- Precision on strings (truncate).
print(string.format("%.3s", "hello"))                -- hel
print("[" .. string.format("%10.3s", "hello") .. "]")-- [       hel]

-- Precision on integers (zero-pad to N digits, %0d means empty for 0).
print(string.format("%.5d", 42))                     -- 00042
print(string.format("%.0d", 0))                      -- (empty)
print(string.format("%.0d", 5))                      -- 5

-- All integer conversions.
print(string.format("%i", 7))                        -- 7
print(string.format("%o", 8))                        -- 10
print(string.format("%u", 42))                       -- 42
print(string.format("%x", 255))                      -- ff
print(string.format("%X", 255))                      -- FF

-- Character conversion.
print(string.format("%c", 65))                       -- A
print(string.format("%c%c%c", 72, 105, 33))          -- Hi!

-- Uppercase float conversions (Lua has %E and %G but no %F).
print(string.format("%E", 12345.0))                  -- 1.234500E+04
print(string.format("%G", 0.0001))                   -- 0.0001
print(string.format("%G", 1.5))                      -- 1.5

-- %q (Lua-readable quoted form).
print(string.format("%q", "hello"))                  -- "hello"
print(string.format("%q", "a\nb"))                   -- "a\<newline>b" (backslash + real newline)
print(string.format("%q", "it's \"x\""))             -- "it's \"x\""

-- %% (literal percent — no arg consumed).
print(string.format("%d%% off!", 25))                -- 25% off!

-- Multiple substitutions, mixed types/specs.
print(string.format("%-5s|%05d|%8.3f", "ab", 7, 3.14159))
                                                     -- ab   |00007|   3.142
