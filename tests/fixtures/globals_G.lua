-- _G — the global-environment table. Every Lua global lives here.

-- Self-reference and identity.
print(_G._G == _G)              -- true
print(type(_G))                 -- table

-- Bidirectional bridging: set through _G, read direct.
_G.x = 42
print(x)                        -- 42

-- ... and the reverse.
y = 100
print(_G.y)                     -- 100

-- Builtins are entries.
print(_G.print == print)        -- true
_G.print("hello via _G")        -- hello via _G

-- Library tables are entries too; nested access works.
print(_G.math.floor(1.7))       -- 1
print(_G.string.upper("ok"))    -- OK

-- Reassigning a builtin (writes a new entry; the original closure is
-- still reachable if held in a local).
local orig_print = print
print = function(...) orig_print("OVERRIDE:", ...) end
print("first")                  -- OVERRIDE:   first
print = orig_print
print("restored")               -- restored

-- Reassign through _G with the same effect.
_G.print = function(s) orig_print("via _G:", s) end
print("from _G")                -- via _G:   from _G
print = orig_print

-- _VERSION through _G.
print(_G._VERSION)              -- Lua 5.5

-- pairs(_G) iterates every entry.
local n = 0
for _ in pairs(_G) do n = n + 1 end
print(n > 10)                   -- true

-- A specific name appears in pairs(_G).
local seen_print = false
for k in pairs(_G) do
  if k == "print" then seen_print = true end
end
print(seen_print)               -- true

-- Removing a global via nil-assignment.
foo = 99
print(_G.foo)                   -- 99
_G.foo = nil
print(foo)                      -- nil
print(_G.foo)                   -- nil

-- _G is not magical: getmetatable is nil.
print(getmetatable(_G))         -- nil
