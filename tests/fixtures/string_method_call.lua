-- Lua's strings have an implicit metatable whose __index is the
-- `string` library, so method-call and field-index forms both work on
-- string values: `"hello":rep(2)` ≡ `string.rep("hello", 2)`.
print(("hello"):rep(2))                     -- hellohello
print(("ab"):upper())                        -- AB
print(("xxx"):len())                         -- 3
print(("hi"):sub(1, 1))                      -- h
-- Field-index form on a string value also works.
local s = "world"
print(s.len, s.len(s))                       -- function  5
-- Calling something missing on a string still throws cleanly.
local ok, err = pcall(function() return ("x"):nope() end)
print(ok, type(err))                         -- false  string
