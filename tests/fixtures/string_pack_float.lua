-- Milestone 21 step 6: float pack/unpack.
-- f (4-byte), d (8-byte), n (8-byte alias for d). Uses
-- exactly-representable values where round-trip prints stably across
-- both our host formatter and reference Lua's tostring.

-- Sizes.
print(#string.pack("f", 0))               -- 4
print(#string.pack("d", 0))               -- 8
print(#string.pack("n", 0))               -- 8

-- Round-trip exact values.
print(string.unpack("d", string.pack("d", 0.0)))    -- 0.0  9
print(string.unpack("d", string.pack("d", 1.0)))    -- 1.0  9
print(string.unpack("d", string.pack("d", -1.0)))   -- -1.0  9
print(string.unpack("d", string.pack("d", 0.5)))    -- 0.5  9
print(string.unpack("d", string.pack("d", 1.5)))    -- 1.5  9
print(string.unpack("n", string.pack("n", 42.5)))   -- 42.5  9

print(string.unpack("f", string.pack("f", 1.0)))    -- 1.0  5
print(string.unpack("f", string.pack("f", -0.5)))   -- -0.5  5
print(string.unpack("f", string.pack("f", 256.0)))  -- 256.0  5

-- inf / -inf.
print(string.unpack("d", string.pack("d", 1/0)))    -- inf  9
print(string.unpack("d", string.pack("d", -1/0)))   -- -inf  9
print(string.unpack("f", string.pack("f", 1/0)))    -- inf  5

-- Integer arg promoted to float before packing.
print(string.unpack("d", string.pack("d", 42)))     -- 42.0  9

-- Byte layout: 1.0 (f) = 0x3f800000. LE = 00 00 80 3f; BE = 3f 80 00 00.
local le = string.pack("<f", 1.0)
print(string.byte(le, 1), string.byte(le, 2),
      string.byte(le, 3), string.byte(le, 4))       -- 0  0  128  63
local be = string.pack(">f", 1.0)
print(string.byte(be, 1), string.byte(be, 2),
      string.byte(be, 3), string.byte(be, 4))       -- 63  128  0  0

-- 1.0 (d) = 0x3ff0000000000000. Spot-check the high byte under both endians.
local ld = string.pack("<d", 1.0)
print(string.byte(ld, 1), string.byte(ld, 8))       -- 0  63
local bd = string.pack(">d", 1.0)
print(string.byte(bd, 1), string.byte(bd, 8))       -- 63  0

-- NaN: round-trip via packed bytes (nan ~= nan, so compare i64 pattern).
local nan = string.pack("d", 0/0)
print(#nan)                                          -- 8
-- Re-unpack as J to capture the bit pattern, repack as d, compare bytes.
local bits = string.unpack("J", nan)
local nan2 = string.pack("J", bits)
print(nan == nan2)                                   -- true

-- Mixed-type alignment under !8.
local mix = string.pack("!8 b d", 1, 2.5)
print(#mix)                                          -- 16 (b at 0, pad 7, d at 8..16)
print(string.unpack("!8 b d", mix))                 -- 1  2.5  17
