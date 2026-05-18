-- utf8.len(s [, i [, j [, lax]]]) — count codepoints starting in [i, j].

-- Empty / ASCII.
print(utf8.len(""))                              -- 0
print(utf8.len("hello"))                         -- 5

-- Single multi-byte codepoints.
print(utf8.len(utf8.char(233)))                  -- 1   (é, 2 bytes)
print(#utf8.char(233))                           -- 2   (byte length)

print(utf8.len(utf8.char(9731)))                 -- 1   (snowman, 3 bytes)
print(utf8.len(utf8.char(128512)))               -- 1   (emoji, 4 bytes)

-- Mixed widths.
print(utf8.len("a" .. utf8.char(233) .. utf8.char(9731) .. utf8.char(128512)))
                                                 -- 4

-- Byte-range arguments (1-based, inclusive).
print(utf8.len("hello", 2, 4))                   -- 3
print(utf8.len("hello", -2))                     -- 2   (negative i)
print(utf8.len("hello", 1, -2))                  -- 4

-- Invalid sequence: returns nil + position of bad byte.
-- 192 (0xC0) is a 2-byte lead with no continuation following.
print(utf8.len(string.char(192)))                -- nil   1

-- 254 (0xFE) is an invalid lead byte in strict mode.
print(utf8.len("a" .. string.char(254)))         -- nil   2

-- Lax mode accepts the 5- and 6-byte extended forms.
-- 252 (0xFC) is a 6-byte lead; five continuation bytes follow.
print(utf8.len(string.char(252, 128, 128, 128, 128, 128), 1, -1, true))
                                                 -- 1

-- Range [i, j] with i > j: count 0.
print(utf8.len("hello", 5, 1))                   -- 0
