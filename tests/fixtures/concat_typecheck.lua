-- `..` only accepts string or number operands (modulo __concat, not yet
-- implemented). Anything else raises a catchable error.

-- Valid concats.
print("a" .. "b")            -- ab
print("a" .. 1)              -- a1
print(1 .. "a")              -- 1a
print(1 .. 2)                -- 12
print(1.5 .. "x")            -- 1.5x

-- nil / bool / table / function: error.
print(pcall(function() return "a" .. nil end))     -- false   nil
print(pcall(function() return "a" .. true end))    -- false   nil
print(pcall(function() return "a" .. false end))   -- false   nil
print(pcall(function() return "a" .. {} end))      -- false   nil
print(pcall(function() return nil .. "a" end))     -- false   nil
print(pcall(function() return print .. "a" end))   -- false   nil

-- print() can still take nil/bool/table — it uses tostring per arg, not
-- the raw concat operator.
print(nil)                  -- nil
print(true, nil, false)     -- true   nil   false
print({}, nil)              -- (table   nil; table form prints "table")
