-- Lua 5.5: a single attribute before the name list applies to every
-- name in the list, like `local <const> a, b = 10, 20`.
local <const> a, b = 10, 20
print(a, b)
-- Per-name attribute (already supported) still wins for that name.
local c <const>, d = 30, 40
print(c, d)
