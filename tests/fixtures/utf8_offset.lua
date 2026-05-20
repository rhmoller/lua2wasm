-- utf8.offset(s, n [, i]) — locate the n-th codepoint relative to byte i.
-- Lua 5.5 returns BOTH the start and end byte position of the codepoint.
-- Default i = 1 (n >= 0) or #s+1 (n < 0).

local s = "a" .. utf8.char(233) .. utf8.char(9731) .. utf8.char(128512) .. "z"
-- byte layout (1-based):
--   a   = byte 1
--   é   = bytes 2..3
--   ☃   = bytes 4..6
--   😀  = bytes 7..10
--   z   = byte 11

print(#s)                            -- 11

-- Positive n: forward indexing from default i = 1 (start, end).
print(utf8.offset(s, 1))             -- 1 1
print(utf8.offset(s, 2))             -- 2 3
print(utf8.offset(s, 3))             -- 4 6
print(utf8.offset(s, 4))             -- 7 10
print(utf8.offset(s, 5))             -- 11 11
print(utf8.offset(s, 6))             -- 12 12  (one past end is a valid position)
print(utf8.offset(s, 7))             -- nil    (past end+1)

-- Negative n: backward from default i = #s + 1.
print(utf8.offset(s, -1))            -- 11 11  ('z')
print(utf8.offset(s, -2))            -- 7 10   (emoji)
print(utf8.offset(s, -3))            -- 4 6    (snowman)
print(utf8.offset(s, -4))            -- 2 3    (é)
print(utf8.offset(s, -5))            -- 1 1
print(utf8.offset(s, -6))            -- nil

-- n = 0: the codepoint containing byte i (start, end).
print(utf8.offset(s, 0, 1))          -- 1 1    (already a lead)
print(utf8.offset(s, 0, 3))          -- 2 3    (byte 3 is é's tail)
print(utf8.offset(s, 0, 5))          -- 4 6    (byte 5 is snowman's middle)
print(utf8.offset(s, 0, 10))         -- 7 10   (byte 10 is emoji's tail)
print(utf8.offset(s, 0, 11))         -- 11 11  ('z' is its own lead)

-- Explicit i.
print(utf8.offset(s, 1, 2))          -- 2 3    (first char starting at i=2 is é)
print(utf8.offset(s, 2, 2))          -- 4 6    (next char after é)
print(utf8.offset(s, -1, 4))         -- 2 3    (back 1 from byte 4)

-- i = #s + 1 (right past the end) is a valid starting position.
print(utf8.offset(s, 1, 12))         -- 12 12

-- A position outside [1, #s+1] is a "position out of bounds" error; a
-- position that lands on a continuation byte (with non-zero n) is also an
-- error. The parenthesized pcall yields just the boolean status, so the
-- assertions are portable (error wording / chunk name are not compared).
print((pcall(utf8.offset, s, 1, 13)))   -- false  (i > #s+1)
print((pcall(utf8.offset, s, 1, 0)))    -- false  (i < 1)
print((pcall(utf8.offset, s, 1, 3)))    -- false  (byte 3 is a continuation byte)
