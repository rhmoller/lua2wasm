-- Strings have a metatable ({__index = string}); reference exposes it via
-- getmetatable, and all strings share the same one. (lua2wasm returned nil.)
print(getmetatable("abc") ~= nil)               -- true
print(getmetatable("") == getmetatable("xyz"))  -- true  (shared, single object)
print(getmetatable("abc").__index == string)    -- true
print(getmetatable("abc").__index.upper == string.upper)  -- true
print(("hello"):upper())                         -- HELLO (method dispatch intact)

-- Other primitives still have no metatable (and must not trap).
print(getmetatable(5), getmetatable(true), getmetatable(nil))  -- nil nil nil
print(getmetatable({}))                          -- nil (plain table)

-- A table's own metatable is returned; __metatable still shadows it.
print(getmetatable(setmetatable({}, {__index = {}})) ~= nil)   -- true
print(getmetatable(setmetatable({}, {__metatable = "X"})))     -- X
