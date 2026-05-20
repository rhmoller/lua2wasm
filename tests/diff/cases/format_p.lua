-- string.format("%p"): address-bearing values (string/table/function) format
-- as "0x<addr>"; valueless types (number/boolean/nil) are "(null)" — matching
-- reference lua_topointer. The address is implementation-defined, so the
-- pointer cases assert the shape (and table stability/distinctness), not digits.
print(string.format("%p", 4))        -- (null)
print(string.format("%p", true))     -- (null)
print(string.format("%p", nil))      -- (null)
print(string.format("%p", 1.5))      -- (null)

print(string.format("%p", "s"):match("^0x%x+$") ~= nil)     -- true
print(string.format("%p", {}):match("^0x%x+$") ~= nil)      -- true
print(string.format("%p", print):match("^0x%x+$") ~= nil)   -- true

-- embedded alongside other directives
print(string.format("<%p>", {}):match("^<0x%x+>$") ~= nil)             -- true
print(string.format("k=%d p=%p", 5, {}):match("^k=5 p=0x%x+$") ~= nil) -- true

-- a table's %p is stable; distinct tables differ
local t = {}
print(string.format("%p", t) == string.format("%p", t))     -- true
print(string.format("%p", {}) ~= string.format("%p", {}))   -- true
