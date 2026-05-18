-- utf8.charpattern is the (Lua-pattern) string that matches exactly one
-- UTF-8 codepoint: "[\0-\x7F\xC2-\xFD][\x80-\xBF]*"
-- (string.gmatch over it isn't implemented yet, but the constant must
-- exist with the right bytes so user code that needs the value can
-- access it.)

-- Length is fixed at 14 bytes.
print(#utf8.charpattern)                  -- 14

-- Each byte at its expected offset.
print(string.byte(utf8.charpattern, 1))   -- 91    '['
print(string.byte(utf8.charpattern, 2))   -- 0     \0
print(string.byte(utf8.charpattern, 3))   -- 45    '-'
print(string.byte(utf8.charpattern, 4))   -- 127   \x7F
print(string.byte(utf8.charpattern, 5))   -- 194   \xC2
print(string.byte(utf8.charpattern, 6))   -- 45    '-'
print(string.byte(utf8.charpattern, 7))   -- 253   \xFD
print(string.byte(utf8.charpattern, 8))   -- 93    ']'
print(string.byte(utf8.charpattern, 9))   -- 91    '['
print(string.byte(utf8.charpattern, 10))  -- 128   \x80
print(string.byte(utf8.charpattern, 11))  -- 45    '-'
print(string.byte(utf8.charpattern, 12))  -- 191   \xBF
print(string.byte(utf8.charpattern, 13))  -- 93    ']'
print(string.byte(utf8.charpattern, 14))  -- 42    '*'

-- It's a regular string value.
print(type(utf8.charpattern))             -- string
