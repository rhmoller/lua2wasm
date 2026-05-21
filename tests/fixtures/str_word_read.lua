-- Exercises the host's word-packed string reader (lua_str_word): strings of
-- every length % 4, plus multibyte UTF-8, all routed through readLuaString via
-- string.format's %s / %q and the format string itself.
for len = 0, 9 do
  io.write(string.format("[%s]=%d ", string.rep("x", len), len))
end
print()
local u = "héllo·wörld"          -- multibyte: byte length not a multiple of 4
print(string.format("%s #=%d", u, #u))
print(string.format("%q", "tab\tq\"uote"))
print(("ABCDEFGHIJ"):lower())     -- a 10-byte string round-trip
