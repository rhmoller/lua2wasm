-- string.reverse(s) — byte-reversed string.
-- (Byte-level, not codepoint-level. Reversing a multi-byte UTF-8
-- sequence produces invalid UTF-8; users wanting codepoint-aware
-- reversal should decode via utf8.codes first.)

print(string.reverse(""))           -- (empty)
print(string.reverse("a"))          -- a
print(string.reverse("ab"))         -- ba
print(string.reverse("hello"))      -- olleh
print(string.reverse("racecar"))    -- racecar  (palindrome)
print(string.reverse("12345"))      -- 54321

-- Returns a fresh string.
local s = "abc"
print(rawequal(s, string.reverse(s)))            -- false
print(rawequal(string.reverse(string.reverse(s)), s)) -- true
