-- string.pack / string.unpack — milestone 21 step 2.
-- Unsigned ints (B H I[N] J L T), x padding, !N alignment, Xop,
-- < > = endianness. Signed ints, floats, c, s, z land in later steps.

-- Sizes.
print(#string.pack("B", 0))                    -- 1
print(#string.pack("H", 0))                    -- 2
print(#string.pack("I4", 0))                   -- 4
print(#string.pack("I1", 0))                   -- 1
print(#string.pack("I8", 0))                   -- 8
print(#string.pack("L", 0))                    -- 8
print(#string.pack("J", 0))                    -- 8
print(#string.pack("T", 0))                    -- 8

-- Byte order: 0x1234 in LE is (0x34, 0x12).
local s = string.pack("H", 0x1234)
print(string.byte(s, 1), string.byte(s, 2))    -- 52  18

-- Round-trips.
print(string.unpack("B", string.pack("B", 200)))           -- 200  2
print(string.unpack("H", string.pack("H", 0xabcd)))        -- 43981  3
print(string.unpack("I4", string.pack("I4", 0x12345678))) -- 305419896  5
print(string.unpack("I3", string.pack("I3", 0xabcdef)))   -- 11259375  4
print(string.unpack("I1", string.pack("I1", 0xff)))        -- 255  2
print(string.unpack("J", string.pack("J", 0x0102030405060708)))
                                                -- 72623859790382856  9
print(string.unpack("T", string.pack("T", 0x7eadbeefcafef00d)))
                                                -- 9128306995481751565  9

-- Multiple values + final position.
print(string.unpack("BHI4", string.pack("BHI4", 1, 0x100, 0x10000)))
                                                -- 1  256  65536  8

-- pos argument advances the cursor.
local m = string.pack("BBB", 7, 8, 9)
print(string.unpack("B", m, 2))                -- 8  3
print(string.unpack("BB", m, 2))               -- 8  9  4

-- x padding writes/reads one zero byte.
local p = string.pack("BxB", 7, 9)
print(#p, string.byte(p, 2))                   -- 3  0
print(string.unpack("BxB", p))                 -- 7  9  4

-- Endianness flags.
local le = string.pack("<I4", 0x01020304)
local be = string.pack(">I4", 0x01020304)
print(string.byte(le, 1), string.byte(le, 2),
      string.byte(le, 3), string.byte(le, 4))  -- 4  3  2  1
print(string.byte(be, 1), string.byte(be, 2),
      string.byte(be, 3), string.byte(be, 4))  -- 1  2  3  4
print(string.unpack(">I4", be))                -- 16909060  5
print(string.unpack("<I4", le))                -- 16909060  5
-- '=' alias for native (LE on us).
print(string.unpack("=I4", le))                -- 16909060  5

-- !N alignment in pack/unpack — same math as packsize.
local a = string.pack("!4 BI4", 7, 0xff)
print(#a)                                       -- 8 (1 + 3 pad + 4)
print(string.byte(a, 1), string.byte(a, 2),
      string.byte(a, 3), string.byte(a, 4))    -- 7  0  0  0
print(string.unpack("!4 BI4", a))              -- 7  255  9

-- Xop aligns without consuming an arg.
local x = string.pack("!4 BXI4 B", 1, 9)
print(#x)                                       -- 5 (1 + 3 align-pad + 1)
print(string.unpack("!4 BXI4 B", x))           -- 1  9  6

-- Overflow rejections (pack only).
print(pcall(string.pack, "B", 256))            -- false  nil
print(pcall(string.pack, "B", -1))             -- false  nil (unsigned: -1 has high bits)
print(pcall(string.pack, "H", 0x10000))        -- false  nil
print(pcall(string.pack, "I3", 0x1000000))     -- false  nil

-- Unsupported-yet options raise (will land in later steps).
print(pcall(string.pack, "s4", "abcd"))        -- false  nil  (s → step 8)
print(pcall(string.unpack, "z", "ab\0c"))      -- false  nil  (z → step 8)
