-- utf8.offset (Lua 5.5): returns the start AND end byte position of the
-- located codepoint (two values); an out-of-range position errors "position
-- out of bounds"; a position that is a continuation byte errors; not-found
-- returns nil. (lua2wasm returned one value and never erred on bad bounds.)
local s = "aλb€"          -- a=1B, λ=2B, b=1B, €=3B; #s == 7

print(utf8.offset(s, 1))    -- 1 1
print(utf8.offset(s, 2))    -- 2 3
print(utf8.offset(s, 3))    -- 4 4
print(utf8.offset(s, 4))    -- 5 7
print(utf8.offset(s, 5))    -- 8 8   (one past the end)
print(utf8.offset(s, -1))   -- 5 7
print(utf8.offset(s, -2))   -- 4 4
print(utf8.offset(s, 0, 3)) -- 2 3   (codepoint containing byte 3)
print(utf8.offset(s, 0, 5)) -- 5 7
print(utf8.offset(s, 1, 2)) -- 2 3

print(utf8.offset("abc", 10))   -- nil  (not found)
print(utf8.offset("abc", -10))  -- nil

local function err(...)
  local ok, e = pcall(utf8.offset, ...)
  return ok, tostring(e):find("position out of bounds", 1, true) ~= nil
end
print(err("abc", 1, 5))     -- false true
print(err("abc", 1, -4))    -- false true
print(err("", 1, 2))        -- false true
print(err("", 1, -1))       -- false true

local function cerr(...)
  local ok, e = pcall(utf8.offset, ...)
  return ok, tostring(e):find("continuation byte", 1, true) ~= nil
end
print(cerr(s, 1, 3))        -- false true  (byte 3 is a continuation byte)
print(cerr("\x80", 1))      -- false true
print(cerr("\x9c", -1))     -- false true  (located byte is a continuation byte)
print(cerr("\x80", 0, 1))   -- false true
