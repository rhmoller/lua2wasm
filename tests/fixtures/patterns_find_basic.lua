-- string.find — step 2 of milestone 20. Pattern engine basics: literals,
-- '.', char-classes, sets, quantifiers, anchors. No captures yet (those
-- come in step 3), no plain mode (step 9).

-- Literals.
print(string.find("hello", "ell"))            -- 2   4
print(string.find("hello", "xyz"))            -- nil

-- '.' wildcard.
print(string.find("xyz", "."))                -- 1   1
print(string.find("xyz", "..."))              -- 1   3
print(string.find("xyz", "...."))             -- nil

-- Anchors.
print(string.find("abc", "^a"))               -- 1   1
print(string.find("abc", "c$"))               -- 3   3
print(string.find("abc", "^abc$"))            -- 1   3
print(string.find("xabc", "^a"))              -- nil

-- Character classes.
print(string.find("hi42", "%d"))              -- 3   3
print(string.find("hi42", "%d+"))             -- 3   4
print(string.find("hi42", "%a+"))             -- 1   2

-- Sets (including ranges and negation).
print(string.find("hello", "[aeiou]"))        -- 2   2
print(string.find("abc1", "[0-9]"))           -- 4   4
print(string.find("aaa1", "[^a]"))            -- 4   4

-- Quantifiers.
print(string.find("aaa", "a*"))               -- 1   3
print(string.find("aaa", "a+"))               -- 1   3
print(string.find("ab", "a?b"))               -- 1   2
print(string.find("b", "a?b"))                -- 1   1
print(string.find("aaa", "a-"))               -- 1   0  (lazy: empty at 1)
print(string.find("aaab", "a-b"))             -- 1   4

-- init argument.
print(string.find("abcabc", "b", 4))          -- 5   5
print(string.find("hello", "l", 5))           -- nil

-- Mixed pattern.
print(string.find("hello123world", "%d+"))    -- 6   8
print(string.find("a=42; b=7", "%a=%d+"))     -- 1   4
