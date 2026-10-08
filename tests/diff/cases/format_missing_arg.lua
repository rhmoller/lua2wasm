-- string.format raises when a conversion has no corresponding argument
-- (found by diff-fuzz: "%s" printed "nil"); an explicit nil is a value.
-- Error wording isn't asserted.
for _, spec in ipairs({"%s", "%d", "%f", "%q", "%c", "%x", "%g", "%5.2s"}) do
  local ok, err = pcall(string.format, spec)
  print(spec, ok, type(err))
end
print(pcall(string.format, "a%sb%s", 1) == false)
print(pcall(function() return string.format("%s", string.byte("\0", 2)) end) == false)
print(string.format("%s %s", 1, nil), string.format("%s", false), string.format("%q", nil))
