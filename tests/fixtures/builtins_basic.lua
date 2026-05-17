-- _VERSION, assert, io.write
print(_VERSION)              -- "Lua 5.5"

assert(true)
assert(1 == 1, "math broken")

-- assert returns its args on success
local x = assert(42, "shouldn't trigger")
print(x)                     -- 42

-- io.write: same as print but no newline, no tab between args
io.write("hello")
io.write(", ")
io.write("world")
io.write("\n")
io.write("a", "b", "c", "\n")

-- assert(false) raises; pcall catches it
local ok, err = pcall(function() assert(false, "boom") end)
print(ok)                    -- false
print(err)                   -- "boom"
