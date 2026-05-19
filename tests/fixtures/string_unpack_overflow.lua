-- string.unpack — overflow detection on sizes > 8 bytes.
-- Mirrors the official tpack.lua "does not fit" checks (lines 88-90, 129).

-- Unsigned: any non-zero upper byte means value exceeds u64. Errors.
print(pcall(string.unpack, "<I9", "\0\0\0\0\0\0\0\0\1"))
print(pcall(string.unpack, "<I16", "\0\0\0\0\0\0\0\0" .. string.rep("\0", 7) .. "\1"))
print(pcall(string.unpack, ">I9", "\1\0\0\0\0\0\0\0\0"))

-- Signed: upper bytes must match sign extension of low 8 bytes.
-- BE i9 with high byte 1 and zeros: full value > i64 max. Errors.
print(pcall(string.unpack, ">i9", "\1\0\0\0\0\0\0\0\0"))
-- BE i16 with 0x03 in every byte: high byte 0x03 != 0x00 sign-fill. Errors.
print(pcall(string.unpack, ">i16", string.rep("\3", 16)))
-- LE i9: low 8 bytes are 0 (positive), upper byte 0xff. Sign mismatch. Errors.
print(pcall(string.unpack, "<i9", "\0\0\0\0\0\0\0\0\xff"))

-- Edges that DO fit and round-trip:
-- 9-byte LE unsigned, upper byte 0 → fits.
print(string.unpack("<I9", "\1\2\3\4\5\6\7\8\0"))
-- 9-byte LE signed negative: low 8 bytes = -1, upper byte 0xff (sign-fill) → fits.
print(string.unpack("<i9", "\xff\xff\xff\xff\xff\xff\xff\xff\xff"))
-- 9-byte LE signed positive: low 8 bytes positive, upper byte 0 → fits.
print(string.unpack("<i9", "\1\0\0\0\0\0\0\0\0"))
-- 16-byte BE signed negative: low 8 bytes = -1, upper 8 bytes all 0xff → fits.
print(string.unpack(">i16", string.rep("\xff", 16)))
