-- utf8.char(...) — encode integer codepoints into a UTF-8 string.

-- ASCII (1-byte per codepoint).
print(utf8.char(65, 66, 67))            -- ABC
print(utf8.char(72, 105, 33))           -- Hi!
print(utf8.char())                      -- (empty)
print(#utf8.char(65))                   -- 1

-- 2-byte UTF-8 (Latin-1 supplement).
local s = utf8.char(233)                -- é (0xE9)
print(#s, s)                            -- 2   é

-- 3-byte UTF-8 (BMP).
print(#utf8.char(9731))                 -- 3   (snowman ☃ = 0x2603)
print(#utf8.char(20013))                -- 3   (中 = 0x4E2D)

-- 4-byte UTF-8 (supplementary plane).
print(#utf8.char(128512))               -- 4   (😀 = 0x1F600)
print(#utf8.char(127820))               -- 4   (🍌 = 0x1F34C)

-- Round-trip: each char rendered correctly by host print.
print(utf8.char(233, 9731))             -- é☃

-- Concatenation length = sum of byte widths.
print(#utf8.char(65, 233, 9731, 128512))-- 1+2+3+4 = 10

-- Extended range: codepoints above U+10FFFF up to MAXUTF (0x7FFFFFFF) are
-- accepted, encoded as 4–6 byte UTF-8 (matches reference).
print(#utf8.char(1114112))              -- 4   (0x110000)
print(#utf8.char(0x7FFFFFFF))           -- 6

-- Out of range (< 0 or > 0x7FFFFFFF) raises. The parenthesized pcall yields
-- just the boolean status, so error wording / chunk name are not compared.
print((pcall(utf8.char, -1)))           -- false
print((pcall(utf8.char, 0x7FFFFFFF + 1)))  -- false

-- Result is a fresh string each call.
local a = utf8.char(65)
local b = utf8.char(65)
print(a == b)                           -- true (content compare)
