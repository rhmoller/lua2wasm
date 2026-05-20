-- Integer // 0 must raise a *catchable* error (it used to throw a nil payload,
-- so pcall returned nil and string.find(err, ...) itself errored). We check the
-- semantic property — a string error object — not the exact wording.
local ok, err = pcall(function() return 3 // 0 end)
print(ok, type(err))
