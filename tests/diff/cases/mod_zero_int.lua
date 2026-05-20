-- Integer % 0 must raise a *catchable* error (was a nil payload). We check the
-- semantic property — a string error object — not the exact wording.
local ok, err = pcall(function() return 3 % 0 end)
print(ok, type(err))
