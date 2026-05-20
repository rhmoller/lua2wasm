-- utf8.char accepts 0..0x7FFFFFFF (Lua's MAXUTF), encoding codepoints above
-- U+10FFFF as extended 4–6-byte UTF-8; out-of-range raises a catchable error.
local function ck(...)
  local ok, e = pcall(...)
  return ok, tostring(e):find("out of range", 1, true) ~= nil
end
local function w(cp) return #utf8.char(cp) end

-- byte counts at the UTF-8 length boundaries
print(w(0), w(0x7F), w(0x80), w(0x7FF), w(0x800), w(0xFFFF))    -- 1 1 2 2 3 3
print(w(0x10000), w(0x10FFFF), w(0x110000), w(0x1FFFFF))        -- 4 4 4 4
print(w(0x200000), w(0x3FFFFFF), w(0x4000000), w(0x7FFFFFFF))   -- 5 5 6 6

-- range checks
print(ck(utf8.char, 0x7FFFFFFF + 1))   -- false true
print(ck(utf8.char, -1))               -- false true

-- surrogates are accepted by utf8.char (3-byte encoding)
print(w(0xD800), w(0xDFFF))            -- 3 3

-- multi-arg, empty, and a normal round-trip
print(utf8.char(104, 105), #utf8.char())                       -- hi 0
print(utf8.char(utf8.codepoint("aλb€", 1, -1)) == "aλb€")     -- true
