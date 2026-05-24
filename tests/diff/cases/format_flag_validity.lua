-- string.format validates flags per conversion (Lua's scanformat): '-' is
-- always allowed; '0' only for numeric; '+'/' ' only for signed numeric;
-- '#' only for o/x/X and floats. An invalid combo raises. Code-review #12.
local flags = { "+", " ", "#", "0", "-" }
local convs = { "d", "i", "u", "o", "x", "X", "c", "f", "e", "g", "s" }
for _, c in ipairs(convs) do
  local row = c .. ":"
  for _, f in ipairs(flags) do
    local ok = pcall(string.format, "%" .. f .. c, (c == "s") and "A" or 65)
    row = row .. " " .. f .. "=" .. (ok and "ok" or "ER")
  end
  print(row)
end
-- valid specs still format correctly
print(string.format("%+d|% d|%#x|%-5d|%05d|%#.0f", 5, 5, 255, 7, 7, 8))
