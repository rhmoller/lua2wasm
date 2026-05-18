-- rawequal(a, b) — equality that never consults __eq

print(rawequal(1, 1))           -- true
print(rawequal(1, 2))           -- false
print(rawequal(1, 1.0))         -- true  (int/float equivalence at integer values)
print(rawequal("a", "a"))       -- true
print(rawequal("a", "b"))       -- false
print(rawequal(nil, nil))       -- true
print(rawequal(nil, false))     -- false
print(rawequal(true, true))     -- true
print(rawequal(true, 1))        -- false  (different types)

local t = {}
print(rawequal(t, t))           -- true
print(rawequal(t, {}))          -- false  (distinct tables)

-- rawequal bypasses __eq: __eq returning true does not make distinct
-- tables raw-equal.
local a = setmetatable({}, { __eq = function() return true end })
local b = setmetatable({}, { __eq = function() return true end })
print(a == b)                   -- true  (via __eq)
print(rawequal(a, b))           -- false (identity)
print(rawequal(a, a))           -- true
