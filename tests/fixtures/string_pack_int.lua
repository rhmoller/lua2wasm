-- Milestone 21 step 3: signed-integer pack/unpack.
-- b h i[N] j l, sign-extended on unpack, range-checked on pack.

-- Single round-trips, full negative + boundary coverage.
print(string.unpack("b", string.pack("b", 0)))       -- 0  2
print(string.unpack("b", string.pack("b", -1)))      -- -1  2
print(string.unpack("b", string.pack("b", 127)))     -- 127  2
print(string.unpack("b", string.pack("b", -128)))    -- -128  2

print(string.unpack("h", string.pack("h", 0)))       -- 0  3
print(string.unpack("h", string.pack("h", -1)))      -- -1  3
print(string.unpack("h", string.pack("h", 32767)))   -- 32767  3
print(string.unpack("h", string.pack("h", -32768)))  -- -32768  3

print(string.unpack("i4", string.pack("i4", -1)))    -- -1  5
print(string.unpack("i4", string.pack("i4", 2147483647)))  -- 2147483647  5
print(string.unpack("i4", string.pack("i4", -2147483648))) -- -2147483648  5
print(string.unpack("i1", string.pack("i1", -1)))    -- -1  2
print(string.unpack("i3", string.pack("i3", -1)))    -- -1  4
print(string.unpack("i3", string.pack("i3", 8388607)))   -- 8388607  4
print(string.unpack("i3", string.pack("i3", -8388608)))  -- -8388608  4

print(string.unpack("j", string.pack("j", -1)))      -- -1  9
print(string.unpack("l", string.pack("l", -1)))      -- -1  9

-- Negative byte pattern: -1 packs to all-0xff.
local s = string.pack("b", -1)
print(string.byte(s, 1))                              -- 255

-- BE byte order for signed.
local s2 = string.pack(">i4", -2)
print(string.byte(s2, 1), string.byte(s2, 2),
      string.byte(s2, 3), string.byte(s2, 4))        -- 255  255  255  254
print(string.unpack(">i4", s2))                      -- -2  5

-- Multi-value with mixed signed/unsigned.
local m = string.pack("bBh", -1, 200, -1000)
print(string.unpack("bBh", m))                       -- -1  200  -1000  5

-- Signed overflow rejections.
print(pcall(string.pack, "b", 128))                  -- false  nil
print(pcall(string.pack, "b", -129))                 -- false  nil
print(pcall(string.pack, "h", 32768))                -- false  nil
print(pcall(string.pack, "h", -32769))               -- false  nil
print(pcall(string.pack, "i3", 8388608))             -- false  nil
print(pcall(string.pack, "i3", -8388609))            -- false  nil

-- !N alignment with signed.
local a = string.pack("!4 bi4", -1, -2)
print(#a, string.unpack("!4 bi4", a))                -- 8  -1  -2  9
