-- What a __close receives, and the errors around to-be-closed variables
-- (after the official locals.lua). With no error in flight, __close gets the
-- value alone; an error exit passes the error as a second argument. A value
-- with no __close is rejected at the declaration, naming the variable; a
-- __close that stopped being callable fails when the scope closes, naming
-- the value's type. Messages are printed without their "<chunk>:<line>:".
local function strip(e) return (string.gsub(tostring(e), "^[^:]*:%d+: ", "")) end
local function counting(tag)
  return setmetatable({}, {__close = function(...)
    print(tag, select("#", ...), (select(2, ...)))
  end})
end

do local a <close> = counting("scope") end
local function ret() local a <close> = counting("return"); return 1 end
ret()
for _ = 1, 2 do local a <close> = counting("break"); break end
do
  local a <close> = counting("goto")
  goto out
end
::out::
pcall(function() local a <close> = counting("error"); error("E", 0) end)
for _ in function() return nil end, nil, nil, counting("for") do end
pcall(function()
  local a <close> = counting("after-raise")
  local b <close> = setmetatable({}, {__close = function() error("B", 0) end})
end)

-- non-closable values
local function msg(f) local ok, e = pcall(f); print(ok, strip(e)) end
msg(function() local x <close> = {} end)
msg(function() local ok <close> = false; local bad_one <close> = 42 end)
msg(function() local p, q <close> = nil, "s" end)
msg(function() for _ in function() end, nil, nil, {} do end end)

-- a __close that is no longer callable
msg(function()
  local x <close> = setmetatable({}, {__close = print})
  getmetatable(x).__close = nil
end)
msg(function()
  local x <close> = setmetatable({}, {__close = print})
  getmetatable(x).__close = 4
  return
end)
msg(function()
  local x <close> = setmetatable({}, {__close = print})
  getmetatable(x).__close = setmetatable({}, {__name = "Thing"})
end)
-- ...still closes the rest, which see that error
msg(function()
  local a1 <close> = setmetatable({}, {__close = function(_, e)
    print("a1 sees", strip(e)); error(12, 0)
  end})
  local a2 <close> = setmetatable({}, {__close = print})
  getmetatable(a2).__close = "nope"
end)
-- a callable table is a fine __close
do
  local x <close> = setmetatable({}, {__close = setmetatable({}, {
    __call = function(_, o, ...) print("callable", select("#", ...)) end})})
end
