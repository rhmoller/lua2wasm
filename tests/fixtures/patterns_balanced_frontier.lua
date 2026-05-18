-- %bxy (balanced match) and %f[set] (frontier).
-- Step 5 of milestone 20.

-- %bxy: walks forward from the current position, treating x as open
-- and y as close, until the depth reaches zero. Matches the entire
-- balanced span.
print(string.match("foo(bar)baz", "%b()"))            -- (bar)
print(string.match("a(b(c)d)e", "%b()"))              -- (b(c)d)
print(string.match("[x[y]z]", "%b[]"))                -- [x[y]z]
print(string.match("no brackets", "%b()"))            -- nil
print(string.find("a((b)c)d", "%b()"))                -- 2   7

-- %f[set]: matches the empty string at the cursor iff the previous
-- byte is NOT in [set] and the current byte IS in [set]. Treats
-- sub[-1] and sub[#s] as \\0 for that check.
print(string.find("hello world", "%f[%a]%a+"))        -- 1   5
print(string.find("hello world", "%f[%a]%a+", 2))     -- 7  11
print(string.match("=foo=bar=", "%f[%w]%w+"))         -- foo
print(string.find("abc abc", "%f[%w]abc"))            -- 1   3
print(string.find("abc abc", "%f[%w]abc", 4))         -- 5   7

-- Frontier at end of string (sub[#s] is treated as 0, not in [%a]).
print(string.find("hello", "%f[%a]"))                 -- 1   0
