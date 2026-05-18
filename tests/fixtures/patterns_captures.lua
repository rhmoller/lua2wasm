-- string.find captures — step 3 of milestone 20.
-- Adds: '(...)' substring captures, '()' position captures, '%n'
-- back-references.

-- Single capture, returned after (start, end).
print(string.find("hello world", "(%a+) (%a+)"))   -- 1   11   hello   world

-- Adjacent literal captures.
print(string.find("abc", "(a)(b)(c)"))             -- 1   3   a   b   c

-- Position capture: '()' records the 1-based byte position.
print(string.find("abcabc", "()a"))                -- 1   1   1
print(string.find("xy123", "()(%d+)()"))           -- 3   5   3   123   6

-- Nested captures.
print(string.find("foo(bar)baz", "(%(.-%))"))      -- 4   8   (bar)
print(string.find("aAbB", "((%a)(%a))"))           -- 1   2   aA   a   A

-- Back-reference: %1 must match the same bytes as capture 1.
print(string.find("abab", "(a)b%1"))               -- 1   3   a
print(string.find("xyzxyz", "(%a+)%1"))            -- 1   6   xyz
print(string.find("xyzqwz", "(%a)%1"))             -- nil  (no doubled letter)

-- Greedy capture with quantifier inside.
print(string.find("hello", "(%a+)"))               -- 1   5   hello
print(string.find("a1b2c3", "(%d+)"))              -- 2   2   1

-- Empty captures are allowed; an unused alt (a*) at start yields "".
print(string.find("xyz", "(a*)x"))                 -- 1   1
                                                    -- (captures: "")

-- No captures: behaves like step 2.
print(string.find("abc", "b"))                     -- 2   2
print(string.find("abc", "x"))                     -- nil
