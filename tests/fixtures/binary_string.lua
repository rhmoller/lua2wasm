-- Lua strings are byte arrays: arbitrary (non-UTF-8) bytes must round-trip
-- through print / io.write / string.format exactly, not be re-encoded as
-- UTF-8 (string.char(255) used to emit the 3-byte U+FFFD instead).
io.write(string.char(255, 254, 0, 65, 128, 10))     -- raw bytes incl. NUL + LF
io.write(string.format("[%s]\n", string.char(200, 201)))
io.write("é\n")                                      -- source UTF-8 bytes C3 A9
-- value-level checks (also exercises readLuaString on raw bytes)
print(#string.char(255, 254, 0), ("\xff\xfe"):byte(1), ("\xff\xfe"):byte(2))
