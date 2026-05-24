-- string.format: plain %s keeps an embedded NUL, but %s with any modifier
-- (width/precision/flags) requires a NUL-free string, like Lua ("string
-- contains zeros"). Fuzzer-found.
local function bad(...) local ok, e = pcall(string.format, ...); return ok, type(e) end
print("plain   ", (pcall(string.format, "%s", "a\0b")))  -- true (NUL kept)
print("len     ", #string.format("%s", "a\0b"))          -- 3
print(".3s     ", bad("%.3s", "a\0b"))     -- false string
print("5s      ", bad("%5s", "a\0b"))      -- false string
print("-5s     ", bad("%-5s", "a\0b"))     -- false string
print(".10s    ", bad("%.10s", "a\0b"))    -- false string
print("clean   ", (pcall(string.format, "%5s", "ab")))   -- true (no NUL)
print(".3sclean", string.format("%.3s", "abcdef"))       -- abc
