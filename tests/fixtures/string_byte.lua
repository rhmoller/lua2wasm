-- string.byte(s [, i [, j]]) — returns the byte values of s[i..j].

print(string.byte("A"))               -- 65
print(string.byte("ABC"))             -- 65    (i defaults to 1)
print(string.byte("ABC", 2))          -- 66
print(string.byte("ABC", 1, 3))       -- 65    66    67  (multi-return)
print(string.byte("hello", -1))       -- 111   (last byte, 'o')
print(string.byte("hello", -3, -1))   -- 108   108   111 ('llo')

-- Empty / out-of-range cases produce no values.
print(string.byte(""))                 -- (nothing)
print(string.byte("", 1))              -- (nothing)
print(string.byte("abc", 5))           -- (nothing — out of range)
print(string.byte("abc", 2, 1))        -- (nothing — empty range)

-- Multi-return into a table constructor.
local t = {string.byte("ABC", 1, 3)}
print(#t, t[1], t[2], t[3])           -- 3   65   66   67

-- select('#', ...) counts the values.
print(select("#", string.byte("hello", 1, 5)))   -- 5

-- byte/char round-trip.
local b = string.byte("z")
print(b)                              -- 122
