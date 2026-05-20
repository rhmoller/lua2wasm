-- utf8.len and utf8.codepoint validate their position arguments (Lua 5.5):
-- an out-of-range position is a catchable "...out of bounds" error, not a
-- silent clamp. Valid ranges, the empty interval, and the (nil, errpos)
-- invalid-byte result are unchanged.
local function ck(...)
  local ok, e = pcall(...)
  return ok, tostring(e):find("out of bounds", 1, true) ~= nil
end

-- utf8.len
print(ck(utf8.len, "abc", 0))        -- false true  (initial < 1)
print(ck(utf8.len, "abc", 5))        -- false true  (initial > #s+1)
print(ck(utf8.len, "abc", 1, 4))     -- false true  (final > #s)
print(utf8.len("abc"))               -- 3
print(utf8.len("aλb€"))              -- 4
print(utf8.len("abc", 2, 3))         -- 2
print(utf8.len("abc", 4))            -- 0   (initial == #s+1 is valid → empty)
print(utf8.len("abcd", 3, 1))        -- 0   (empty interval)
print(utf8.len("a\xffb"))            -- nil 2  (invalid byte → nil, position)

-- utf8.codepoint
print(ck(utf8.codepoint, "abc", 0))      -- false true
print(ck(utf8.codepoint, "abc", 4))      -- false true  (> #s)
print(ck(utf8.codepoint, "abc", 1, 4))   -- false true
print(utf8.codepoint("abc"))             -- 97
print(utf8.codepoint("abc", 1, 3))       -- 97 98 99
print(utf8.codepoint("aλb€", 1, -1))     -- 97 955 98 8364
print(select("#", utf8.codepoint("abc", 2, 1)))  -- 0  (empty interval)
