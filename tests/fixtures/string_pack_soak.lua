-- Milestone 21 step 9: soak fixture for string.pack/unpack/packsize.
-- Covers every option documented in manual §6.5.2 in a mix of
-- combinations, plus a long round-trip. Output must match reference
-- Lua 5.5 byte-for-byte; the soak is what locks in spec conformance.

-- ===== Block A: per-option byte-layout spot checks =====

-- Unsigned ints (LE), full width.
print(string.byte(string.pack("B", 0xab), 1))           -- 171
print(string.byte(string.pack("H", 0x0102), 1, 2))      -- 2 1
print(string.byte(string.pack("I4", 0x01020304), 1, 4)) -- 4 3 2 1
print(string.byte(string.pack("I3", 0x010203), 1, 3))   -- 3 2 1
print(string.byte(string.pack("J", 0x0102030405060708), 1, 8))

-- Signed -1 fills with 0xff bytes regardless of width.
print(string.byte(string.pack("b", -1), 1))             -- 255
print(string.byte(string.pack("h", -1), 1, 2))          -- 255 255
print(string.byte(string.pack("i4", -1), 1, 4))         -- 255 255 255 255

-- Endianness flips byte order; widths stay the same.
print(string.byte(string.pack("<I4>I4=I4", 1, 1, 1), 1, 12))

-- Floats: 1.0 (d) = 0x3ff0000000000000.
print(string.byte(string.pack(">d", 1.0), 1, 8))        -- 63 240 0 0 0 0 0 0
-- 1.0 (f) = 0x3f800000.
print(string.byte(string.pack("<f", 1.0), 1, 4))        -- 0 0 128 63

-- c[N] pads with zeros; z appends one zero; s[N] prefixes a length.
print(string.byte(string.pack("c5", "hi"), 1, 5))        -- 104 105 0 0 0
print(string.byte(string.pack("z",  "hi"), 1, 3))        -- 104 105 0
print(string.byte(string.pack("s1", "hi"), 1, 3))        -- 2 104 105
print(string.byte(string.pack(">s2", "hi"), 1, 4))       -- 0 2 104 105

-- Padding and align-only.
print(string.byte(string.pack("BxB", 1, 2), 1, 3))       -- 1 0 2
print(string.byte(string.pack("!4 BI4", 1, 0), 1, 8))    -- 1 0 0 0 0 0 0 0
print(string.byte(string.pack("!4 BXI4 B", 1, 9), 1, 5)) -- 1 0 0 0 9

-- ===== Block B: packsize for the fixed-size subset =====
print(string.packsize("BHI4Jbi3"))                       -- 1+2+4+8+1+3 = 19
print(string.packsize("!4 BHI4Jbi4"))                    -- 1+1pad+2+4+8+1+3pad+4 = 24
print(string.packsize("c10 b c2 H"))                     -- 10+1+2+2 = 15
print(string.packsize("!8 b d"))                         -- 1+7pad+8 = 16
print(string.packsize("<i4>i4=i4"))                      -- 12

-- ===== Block C: long round-trip =====
local fmt = "!8 b H I4 j f d c4 z s1 s4 B"
local s = string.pack(fmt,
  -1, 0xfeed, 0xcafebabe, 0x12345678, 1.5, 3.25,
  "ABCD", "hello", "hi", "world", 200)
print(#s)
-- Round-trip: every value comes back unchanged.
local b, H, I4, j, f, d, c4, z, s1, s4, B, pos = string.unpack(fmt, s)
print(b, H, I4, j, f, d, c4, z, s1, s4, B, pos)
-- Sanity: pos one past total length.
print(pos == #s + 1)

-- ===== Block D: gmatch-style "consume until done" via pos =====
-- A stream of 4 little-endian I2 values, each followed by a B tag.
local stream = string.pack("<I2 B I2 B I2 B I2 B", 10, 0x41, 20, 0x42, 30, 0x43, 40, 0x44)
print(#stream)                                            -- 4 * (2 + 1) = 12
local p = 1
for i = 1, 4 do
  local v, tag, np = string.unpack("<I2 B", stream, p)
  print(v, tag)
  p = np
end
print(p == #stream + 1)                                   -- true

-- ===== Block E: BE/LE cross-check =====
-- Same integer packed both ways unpacks to the same value.
local val = 0x55667788
local le = string.pack("<i4", val)
local be = string.pack(">i4", val)
print(string.unpack("<i4", le) == val and string.unpack(">i4", be) == val)
-- Endian flag persists across multiple options.
local sw = string.pack("<I4 I4", 1, 2)
print(string.byte(sw, 1), string.byte(sw, 8))             -- 1  0
local swb = string.pack(">I4 I4", 1, 2)
print(string.byte(swb, 4), string.byte(swb, 5))           -- 1  0
