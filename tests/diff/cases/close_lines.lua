-- Error positions around to-be-closed variables. A __close metamethod
-- removed after the declaration fails when the scope closes, reported at the
-- line reference Lua is on when it leaves the scope: the last token of the
-- block (a function body's `end`), the return/break/goto that exits it. A
-- non-closable value fails at its declaration. Only the line is printed.
local function closable()
  local mt = {__close = function() end}
  return setmetatable({}, mt), mt
end
local function at(f)
  local ok, e = pcall(f)
  print(ok, (tostring(e):match(":(%d+):")))
end

at(function()
  local v, mt = closable()
  local a <close> = v
  mt.__close = nil
  local x = 1
end)

at(function()
  local v, mt = closable()
  local a <close> = v
  mt.__close = nil
  do return 1 end
end)

at(function()
  do
    local v, mt = closable()
    local a <close> = v
    mt.__close = nil
  end
end)

at(function()
  for _ = 1, 1 do
    local v, mt = closable()
    local a <close> = v
    mt.__close = nil
  end
end)

at(function()
  while true do
    local v, mt = closable()
    local a <close> = v
    mt.__close = nil
    if true then
      break
    end
  end
end)

at(function()
  repeat
    local v, mt = closable()
    local a <close> = v
    mt.__close = nil
  until
    true
end)

at(function()
  local v, mt = closable()
  local n = 0
  for _ in function() n = n + 1; if n == 1 then mt.__close = nil; return 1 end end, nil, nil, v do
    local x = 1
  end
end)

at(function()
  local v, mt = closable()
  do
    local a <close> = v
    mt.__close = nil
    goto out
  end
  ::out::
end)

-- non-closable values fail at the declaration
at(function()
  local ok <close> = closable()

  local bad <close> = {}
end)
at(function()
  for _ in function() return nil end, nil, nil, {} do end
end)
