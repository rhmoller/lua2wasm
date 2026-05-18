-- __concat: called when either `..` operand is non-string-non-number.
-- __len:    called for `#x` on tables (overrides border) and on any
--           non-string/non-table value. Strings always use byte length
--           without consulting __len.

local a = setmetatable({}, { __concat = function(x, y) return "A:" .. tostring(y) end })
local b = setmetatable({}, { __concat = function(x, y) return "B:" .. tostring(x) end })

-- a on the LEFT: handler called with (a, "x") -> "A:x"
print(a .. "x")              -- A:x
-- a on the RIGHT, left is plain: a's handler still fires (right-side
-- fallback in $arith_mm), called with ("x", a) -> "A:" .. tostring(a)
print("x" .. a)              -- A:table
-- Both have metamethods: LEFT operand's handler wins.
print(a .. b)                -- A:table

-- Pure-string/number concat path unchanged.
print("hi" .. " " .. 42)     -- hi 42
print(1 .. 2)                -- 12

-- __len on a table overrides the array-border rule.
local t = setmetatable({1, 2, 3}, { __len = function() return 99 end })
print(#t)                    -- 99

-- __len on a non-table value (here, a table without sequence content,
-- to mimic 'opaque' behaviour).
local p = setmetatable({}, { __len = function() return 7 end })
print(#p)                    -- 7

-- Strings always use byte length, even with a metatable that would
-- carry __len if it were a table.
print(#"hello")              -- 5
print(#"")                   -- 0

-- A table without __len still uses the border rule.
print(#{10, 20, 30})         -- 3

-- Missing metamethod on a non-len-able value → catchable error.
print(pcall(function() return #true end))          -- false   nil
print(pcall(function() return {} .. {} end))       -- false   nil
