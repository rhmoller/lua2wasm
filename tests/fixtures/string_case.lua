-- string.upper / string.lower — ASCII-only case mapping.
-- Non-ASCII bytes pass through unchanged.

print(string.upper("hello"))           -- HELLO
print(string.upper("Hello, World!"))   -- HELLO, WORLD!
print(string.upper(""))                -- (empty)
print(string.upper("abc XYZ 123 !@#")) -- ABC XYZ 123 !@#

print(string.lower("HELLO"))           -- hello
print(string.lower("Hello, World!"))   -- hello, world!
print(string.lower(""))                -- (empty)
print(string.lower("ABC xyz 123 !@#")) -- abc xyz 123 !@#

-- Non-ASCII bytes (a UTF-8 'é' = C3 A9) are not touched.
print(string.upper("a\xC3\xA9"))        -- Aé  (only 'a' mapped)
print(string.lower("A\xC3\x89"))        -- aÉ-byte-passthrough (only 'A' mapped)

-- rawequal compares strings by content, so content equality is what we
-- check here (identity is not user-visible for strings).
local s = "abc"
print(rawequal(s, string.upper(s)))    -- false  (content differs)
print(rawequal(s, string.lower(s)))    -- true   (content unchanged)
