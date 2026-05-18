-- Milestone 21 step 8: z (zero-terminated) and s[N] (length-prefixed).
-- Both are variable-length and packsize-incompatible. Body bytes are
-- not aligned. s's length prefix follows the alignment of an N-byte
-- unsigned int.

-- z round-trips, sizes, byte layout.
print(string.unpack("z", string.pack("z", "hello")))    -- hello  7
print(#string.pack("z", "hi"))                           -- 3
print(string.byte(string.pack("z", "ab"), 1, 3))         -- 97  98  0
print(string.byte(string.pack("z", ""), 1))              -- 0 (just the terminator)

-- z unpack consumes through the first NUL only.
print(string.unpack("z", "abc\0xyz\0"))                  -- abc  5

-- z with embedded NUL → reject.
print(pcall(string.pack, "z", "a\0b"))                   -- false  nil

-- s default size = 8 (size_t).
print(string.unpack("s", string.pack("s", "hello")))    -- hello  14
print(#string.pack("s", "ab"))                           -- 10

-- s with explicit N.
print(#string.pack("s1", "abc"))                         -- 4
print(#string.pack("s2", "abc"))                         -- 5
print(#string.pack("s4", "abc"))                         -- 7

-- s1 length prefix byte.
print(string.byte(string.pack("s1", "xy"), 1))           -- 2
print(string.byte(string.pack("s1", "xy"), 2, 3))        -- 120  121

-- s1 length-overflow rejection (length > 255).
print(pcall(string.pack, "s1", string.rep("a", 300)))    -- false  nil

-- Endianness affects the length prefix byte order.
local sle = string.pack("<s2", "hi")
local sbe = string.pack(">s2", "hi")
print(string.byte(sle, 1), string.byte(sle, 2))          -- 2  0
print(string.byte(sbe, 1), string.byte(sbe, 2))          -- 0  2

-- s round-trip across endianness.
print(string.unpack(">s2", sbe))                         -- hi  5
print(string.unpack("<s2", sle))                         -- hi  5

-- Mixed with ints.
local m = string.pack("Bs1B", 7, "hi", 9)
print(#m, string.unpack("Bs1B", m))                      -- 5  7  hi  9  6

-- s length prefix alignment under !4: prefix aligns to min(4, !4)=4.
local sa = string.pack("!4 b s4", 1, "X")
print(#sa)                                                -- b@0 + pad 3 + s4 prefix 4 + body 1 = 9
print(string.unpack("!4 b s4", sa))                      -- 1  X  10

-- packsize still rejects s and z (unchanged).
print(pcall(string.packsize, "s"))                       -- false  nil
print(pcall(string.packsize, "z"))                       -- false  nil

-- Body bytes are NOT aligned: s prefix lands aligned, then next
-- option re-aligns independently.
local sb = string.pack("!4 s1 H", "ab", 0xcdef)
print(#sb)                                                -- s1 prefix 1 + body 2 = 3; pad 1; H 2 = 6
print(string.unpack("!4 s1 H", sb))                      -- ab  52719  7
