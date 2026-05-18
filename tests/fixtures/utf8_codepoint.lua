-- utf8.codepoint(s [, i [, j [, lax]]]) — codepoint values as multi-return.

-- Single ASCII char (default i=1, j=i).
print(utf8.codepoint("A"))                  -- 65
print(utf8.codepoint("ABC"))                -- 65   (only position 1)
print(utf8.codepoint("ABC", 2))             -- 66

-- Multi-return over a byte range.
print(utf8.codepoint("ABC", 1, 3))          -- 65   66   67
print(utf8.codepoint("hello", 1, -1))       -- 104  101  108  108  111

-- Multi-byte codepoints decode to their value, not byte counts.
print(utf8.codepoint(utf8.char(233)))       -- 233    (é)
print(utf8.codepoint(utf8.char(9731)))      -- 9731   (snowman)
print(utf8.codepoint(utf8.char(128512)))    -- 128512 (emoji)

-- Mixed widths in a single string.
local s = "a" .. utf8.char(233) .. utf8.char(9731) .. utf8.char(128512)
print(utf8.codepoint(s, 1, -1))             -- 97   233   9731   128512

-- Round-trip via char.
print(utf8.char(utf8.codepoint("hello", 1, 5)))  -- hello

-- Indexing into a continuation byte is invalid → error.
print(pcall(function() return utf8.codepoint(utf8.char(233), 2) end))   -- false   nil

-- Invalid lead byte in strict mode → error.
print(pcall(function() return utf8.codepoint(string.char(254)) end))    -- false   nil

-- Empty range yields no values.
local n = select("#", utf8.codepoint("hello", 3, 2))
print(n)                                    -- 0
