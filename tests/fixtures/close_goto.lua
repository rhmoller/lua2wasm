-- goto closes any <close> variable whose scope it leaves (reference Lua runs
-- __close on a goto exit, like return/break). Covers a forward goto out of a
-- do-block and a backward goto loop that re-enters the close scope each pass.
local function mk(tag) return setmetatable({}, {__close = function() print("close " .. tag) end}) end

print("-- forward goto out of a do-block --")
do
  do local x <close> = mk("x"); print("before goto"); goto done end
  ::done:: print("after label")
end

print("-- backward goto loop re-enters the close scope --")
local i = 0
::top::
do
  local r <close> = mk("r" .. i)
  i = i + 1
  if i < 3 then goto top end
end
print("loop done, i=" .. i)

print("-- goto staying inside the scope does NOT close early --")
do
  local y <close> = mk("y")
  goto skip
  ::skip:: print("at skip, y still open")
end
print("end")
