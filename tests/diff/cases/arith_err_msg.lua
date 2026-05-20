-- Arithmetic on a non-number must raise a catchable string error (semantic
-- check — exact wording / chunk-name formatting intentionally not asserted).
local ok, err = pcall(function() return nil + 1 end)
print(ok, type(err))
