-- A multi-line string using `\z` to skip whitespace, with hex escapes
-- whose decoded byte counts exceed the source span before the first
-- newline. Pre-scan must not stop at the newline after a \z.
local s = "\0 \x7F\z
     \xC2\x80 \xDF\xBF\z
     \xE0\xA0\x80 \xEF\xBF\xBF\z
     \xF0\x90\x80\x80  \xF4\x8F\xBF\xBF"
print(#s)
-- 21 bytes: \0,sp,\x7F, \xC2,\x80, sp, \xDF,\xBF, \xE0,\xA0,\x80, sp, \xEF,\xBF,\xBF,
--           \xF0,\x90,\x80,\x80, sp,sp, \xF4,\x8F,\xBF,\xBF = 26? let's count
-- explicit: "\0" " " "\x7F"          = 3
--           "\xC2" "\x80" " " "\xDF" "\xBF" = 5  -> 8
--           "\xE0" "\xA0" "\x80" " " "\xEF" "\xBF" "\xBF" = 7 -> 15
--           "\xF0" "\x90" "\x80" "\x80" " " " " "\xF4" "\x8F" "\xBF" "\xBF" = 10 -> 25
print(string.byte(s, 1))   -- 0
print(string.byte(s, 2))   -- 32 (space)
print(string.byte(s, 3))   -- 127 (0x7F)
print(string.byte(s, 4))   -- 194 (0xC2)
print(string.byte(s, -1))  -- 191 (0xBF, last byte of the final 4-byte seq)
