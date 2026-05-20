-- Milestone 21 step 7: fixed-size string c[N].
-- Pack pads with zeros to reach N; raises if input is longer.
-- Unpack always returns N raw bytes (no NUL stripping). Not aligned.
-- Fixture uses string.byte / length to keep NUL bytes out of print
-- output (bash test wrappers can't carry NULs).

-- Short string round-trip (no embedded NULs).
print(string.unpack("c4", string.pack("c4", "abcd")))    -- abcd  5
print(string.unpack("c1", string.pack("c1", "Z")))       -- Z  2

-- Sizes are exact.
print(#string.pack("c10", "ab"))                          -- 10
print(#string.pack("c0", ""))                             -- 0

-- Padding: short string is zero-padded to N (inspect via byte).
print(string.byte(string.pack("c4", "ab"), 1, 4))         -- 97  98  0  0
print(string.byte(string.pack("c10", "hello"), 1, 10))    -- 104 101 108 108 111 0 0 0 0 0

-- c0 is allowed (zero-byte slot).
local s = string.pack("c0", "")
print(#s)                                                  -- 0

-- Position after unpacking c0 (no bytes consumed).
local _, pos = string.unpack("c0", "anything")
print(pos)                                                 -- 1

-- Embedded zero bytes in the input survive (compare full string).
local raw = "a\0b\0"
print(string.unpack("c4", string.pack("c4", raw)) == raw) -- true
print(#string.pack("c4", raw))                             -- 4

-- No alignment: c sits flush against neighbors even under !N.
local s2 = string.pack("!4 b c3 b", 7, "xyz", 9)
print(#s2)                                                 -- 5
print(string.unpack("!4 b c3 b", s2))                     -- 7  xyz  9  6

-- Too long → raise.
print(pcall(string.pack, "c2", "abcd"))                   -- false  data does not fit

-- Mixed with ints (no NULs in payload).
print(string.unpack("Bc3B", string.pack("Bc3B", 7, "abc", 8)))   -- 7  abc  8  6

-- c without [N] is rejected (parser-level).
print(pcall(string.pack, "c", "x"))                       -- false  ...: missing size
