-- To-be-closed variables (Lua 5.4+): a local marked <close> runs its value's
-- __close metamethod the moment it leaves scope -- on normal exit, return,
-- break, goto, or an error. Think RAII: open a resource, and it's released
-- deterministically however the block ends.

-- A tiny "resource" whose __close just logs that it was released.
local function resource(name)
  print("open  " .. name)
  return setmetatable({ name = name }, {
    __close = function(self) print("close " .. self.name) end,
  })
end

print("1) released at end of scope, in reverse order:")
do
  local a <close> = resource("a")
  local b <close> = resource("b")
  print("      ...using a and b...")
end

print("\n2) released even when an error unwinds the block:")
print("   pcall ->", pcall(function()
  local r <close> = resource("r")
  error("boom")
end))

print("\n3) a generic-for's iterator can carry a closing value,")
print("   released when the loop ends (here: after a break):")
local function lines(n)
  local i = 0
  local iter = function() i = i + 1; if i <= n then return "line " .. i end end
  return iter, nil, nil, resource("file")
end
for text in lines(99) do
  print("      " .. text)
  if text == "line 2" then break end
end
