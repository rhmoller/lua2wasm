-- string.match — step 4 of milestone 20.
-- Same scan as find, but returns captures (or the whole match when
-- the pattern has none), nil on no match.

print(string.match("hello", "ell"))                -- ell
print(string.match("hello world", "(%a+) (%a+)"))  -- hello   world
print(string.match("hi=42", "(%a+)=(%d+)"))        -- hi   42
print(string.match("foo bar baz", "%a+"))          -- foo
print(string.match("abc", "x"))                    -- nil
print(string.match("hello", "^(%a)"))              -- h
print(string.match("a/b/c", "(.-)/"))              -- a
print(string.match("a/b/c", "([^/]+)$"))           -- c

-- Position capture by itself returns the position as an integer.
print(string.match("xyz", "()"))                   -- 1
print(string.match("foobar", "foo()bar"))          -- 4   (position between)

-- Multiple captures, one of which is a position.
print(string.match("xy42", "(%a+)()(%d+)"))        -- xy   3   42

-- init argument.
print(string.match("abcabc", "(%a)", 4))           -- a   (the 'a' at position 4)
