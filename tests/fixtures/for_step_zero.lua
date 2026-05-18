-- Numeric `for` with step = 0 should raise a runtime error,
-- not loop forever (matches Lua reference).
local ok, msg = pcall(function()
  for i = 1, 10, 0 do
    print(i)
  end
end)
print(ok)
print(msg)
