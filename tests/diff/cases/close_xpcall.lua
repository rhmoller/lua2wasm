-- xpcall's message handler runs where the error is raised, before anything
-- unwinds (luaG_errormsg), so a <close> variable's __close sees the handler's
-- result, not the raw error. An error raised inside a __close goes through the
-- handler too. Then a nil error object becomes "<no error object>", which is
-- also what __close receives under a plain pcall.
local log = {}
local function L(s) log[#log + 1] = s end
local function flush(tag) print(tag, table.concat(log, " ")); log = {} end
local function mk(tag)
  return setmetatable({}, {__close = function(_, e) L(tag .. ":" .. tostring(e)) end})
end
local function H(m) L("H(" .. tostring(m) .. ")"); return "h<" .. tostring(m) .. ">" end

print(xpcall(function() local a <close> = mk("a"); error("E", 0) end, H))
flush("before-close")

print(xpcall(function()
  local a <close> = mk("a")
  local b <close> = setmetatable({}, {__close = function(_, e) L("b:" .. tostring(e)); error("E2", 0) end})
  error("E1", 0)
end, H))
flush("close-raises")

print(xpcall(function()
  local a <close> = mk("a")
  local b <close> = setmetatable({}, {__close = function() error("E3", 0) end})
  local c <close> = mk("c")
  return "ret"
end, H))
flush("normal-exit-raises")

print(xpcall(function()
  local a <close> = mk("a")
  print(pcall(function() local i <close> = mk("i"); error("inner", 0) end))
  error("outer", 0)
end, H))
flush("pcall-shields")

print(xpcall(function()
  print(xpcall(function() local i <close> = mk("i"); error("inner", 0) end,
               function() L("H2"); return "h2" end))
  error("outer", 0)
end, H))
flush("nested-xpcall")

print(xpcall(function() local a <close> = mk("a"); local t = nil; return t.x end,
             function(m) L("H:" .. type(m)); return "idx" end))
flush("runtime-error")

print(xpcall(function()
  for _ in function() return 1 end, nil, nil, mk("for") do error("F", 0) end
end, H))
flush("for-closing")

print(xpcall(function()
  local a <close> = setmetatable({}, {__close = function()
    L("pc:" .. tostring(select(2, pcall(error, "deep", 0))))
  end})
  error("E", 0)
end, H))
flush("pcall-in-close")

local sum = 0
for i = 1, 5 do
  xpcall(function() local a <close> = mk("x" .. i); error(i, 0) end,
         function(m) sum = sum + m; return m end)
end
print(sum)
flush("loop")

-- the nil error object
print(pcall(function() local a <close> = mk("a"); error() end))
flush("nil-pcall")
print(pcall(function()
  for _ in function() return 1 end, nil, nil, mk("f") do error(nil) end
end))
flush("nil-for")
print(xpcall(function() local a <close> = mk("a"); error() end, H))
flush("nil-xpcall")
print(pcall(function()
  local a <close> = mk("a")
  local b <close> = setmetatable({}, {__close = function() error() end})
end))
flush("nil-from-close")

-- a handler that raises: reference Lua gives up with "error in error handling"
print(xpcall(function() error("E", 0) end, function() error("again", 0) end))
print(xpcall(function() local a <close> = mk("a"); error("E", 0) end,
             function() error("again", 0) end))
flush("handler-raises")
-- ...but one that raises once is called again on its own error
local tries = 0
print(xpcall(function() error("E", 0) end, function(m)
  tries = tries + 1
  if tries == 1 then error("retry", 0) end
  return "h" .. tries .. ":" .. m
end))

-- the handler must be a function
print((pcall(xpcall, function() end, nil)))
print((pcall(xpcall, function() end, {})))

-- stack overflow: the handler still gets room to run
local function deep(n) return 1 + deep(n + 1) end
print(xpcall(deep, function(m) return "SO:" .. tostring(string.find(m, "stack overflow") ~= nil) end, 1))
