-- rawlen(v) — byte length for strings, border length for tables.
-- Errors for other types.

print(rawlen(""))                  -- 0
print(rawlen("hello"))             -- 5
print(rawlen({}))                  -- 0
print(rawlen({10, 20, 30}))        -- 3
print(rawlen({1, 2, 3, x = 99}))   -- 3   (hash part doesn't count)

-- rawlen errors on non-string, non-table values.
local ok = pcall(function() return rawlen(42) end)
print(ok)                          -- false
local ok2 = pcall(function() return rawlen(true) end)
print(ok2)                         -- false
local ok3 = pcall(function() return rawlen(nil) end)
print(ok3)                         -- false
