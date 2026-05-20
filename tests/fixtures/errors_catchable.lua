-- Regression: these builtins used to `throw nil`, which made the error
-- uncatchable (pcall returned `false, nil` and any string.find on the
-- message then errored). Every one must now yield a string error value.
local function kind(f, ...)
  local ok, err = pcall(f, ...)
  print(ok, type(err))
end

kind(function() return rawget(5, 1) end)              -- table expected
kind(function() return rawlen(5) end)                 -- table or string expected
kind(function() return select(0, 1, 2) end)           -- index out of range
kind(function() return require(5) end)                -- string expected
kind(function() return os.getenv() end)               -- string expected
kind(function() return math.fmod(3, 0) end)           -- integer fmod by zero
kind(function() return math.random(5, 1) end)         -- empty interval
kind(function() return string.unpack("i4", "ab") end) -- data does not fit
kind(function() return string.unpack("z", "abc") end) -- unterminated 'z'
