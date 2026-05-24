-- A <close> variable's value is validated at the declaration: a truthy value
-- with no __close metamethod raises right there, so the block body must NOT
-- run. nil and false are always accepted (and never closed).
local function try(v)
  local ran = false
  local ok = pcall(function()
    local x <close> = v
    ran = true
  end)
  return ok, ran
end
local closeable = setmetatable({}, {__close = function() end})
print(try(42))         -- false  false   (number is not closable)
print(try("s"))        -- false  false   (string)
print(try({}))         -- false  false   (table without __close)
print(try(print))      -- false  false   (function)
print(try(nil))        -- true   true    (nil accepted)
print(try(false))      -- true   true    (false accepted)
print(try(closeable))  -- true   true    (has __close)
-- the raised error is catchable and is a string value
local ok, e = pcall(function() local x <close> = 42 end)
print(ok, type(e))     -- false  string
