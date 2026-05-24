-- To-be-closed (<close>) locals must run __close on every exit path:
-- normal fall-through, return, break, and error unwinding — in reverse
-- declaration order, passing the error value on an error exit, and skipping
-- nil/false. (Earlier limitation: only fall-through closed.)
local mt = { __close = function(self, err)
  print("close", self.name, err == nil and "ok" or "err")
end }
local function R(name) return setmetatable({ name = name }, mt) end

-- normal block exit, reverse order
do
  local a <close> = R("a")
  local b <close> = R("b")
  print("in-do")
end

-- close on return (RAII), then a tail-position multi-return
local function f()
  local r <close> = R("ret")
  return 1, 2, 3
end
print("f=", f())

-- close on break, only the iterations actually entered
for i = 1, 3 do
  local r <close> = R("loop" .. i)
  if i == 2 then break end
end

-- close on error unwinding (reverse order, err passed), caught by pcall
local ok = pcall(function()
  local x <close> = R("x")
  local y <close> = R("y")
  error("boom")
end)
print("pcall-ok", ok)

-- nil/false skip __close
do
  local n <close> = nil
  local fa <close> = false
  local g <close> = R("g")
end

-- return through nested close scopes (inner before outer)
local function nested()
  local outer <close> = R("outer")
  do
    local inner <close> = R("inner")
    return "done"
  end
end
print("nested=", nested())

-- captured <close> var: the closure still reads the (closed) value
local function mk()
  local r <close> = R("cap")
  return function() return r.name end
end
print("cap=", mk()())
