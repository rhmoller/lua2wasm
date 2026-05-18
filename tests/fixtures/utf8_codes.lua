-- utf8.codes(s) — iterator yielding (byte_position, codepoint) pairs.
-- Designed for use with the generic for loop.

-- Mixed-width string: a (1 byte) + é (2 bytes) + ☃ (3 bytes) + z (1 byte).
local s = "a" .. utf8.char(233) .. utf8.char(9731) .. "z"
for p, c in utf8.codes(s) do
  print(p, c)
end
-- expect:
-- 1   97
-- 2   233
-- 4   9731
-- 7   122

print("---")

-- Empty string: zero iterations.
for p, c in utf8.codes("") do
  print(p, c)
end
print("(end empty)")

-- Single ASCII char.
for p, c in utf8.codes("Q") do
  print(p, c)               -- 1   81
end

print("---")

-- Pure ASCII produces one entry per byte.
for p, c in utf8.codes("ABC") do
  print(p, c)
end
-- expect 1/65, 2/66, 3/67

print("---")

-- Invalid byte mid-iteration raises a catchable error.
local ok = pcall(function()
  for p, c in utf8.codes("a" .. string.char(254)) do
    print(p, c)
  end
end)
print(ok)                   -- false (the 'a' iteration ran first)
