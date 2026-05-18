-- Milestone 23: <const> and <close> local attributes.
-- <const>: compile-time rejection of reassignment.
-- <close>: __close called at natural block exit, reverse declaration
-- order, nil/false skipped. Error/break/return inside the block do NOT
-- trigger close yet — documented limitation.

-- Basic <const> read.
local pi <const> = 3.14
print(pi)                                              -- 3.14

-- Multiple attribs in one local statement.
local x <const>, y = 1, 2
y = y + 1
print(x, y)                                            -- 1  3

-- <close> with __close.
local resource_mt = {
  __close = function(self, err)
    print("closing", self.name, err == nil and "(no err)" or err)
  end,
}

do
  local r1 <close> = setmetatable({name = "first"}, resource_mt)
  local r2 <close> = setmetatable({name = "second"}, resource_mt)
  print("inside do")
end
print("after do")

-- Output:
--   inside do
--   closing  second  (no err)
--   closing  first   (no err)
--   after do

-- nil and false skip __close lookup.
do
  local n <close> = nil
  local f <close> = false
  local g <close> = setmetatable({name = "G"}, resource_mt)
  print("body")
end
print("end")

-- <close> on a value with no __close raises at close time (caught
-- by pcall here). Function body is a block; close emission fires
-- at its end like any other block.
local ok, _err = pcall(function()
  local bad <close> = setmetatable({}, {})    -- no __close
end)
print("noclose-pcall returned ok =", ok)

-- <const> with a non-numeric value still works.
local greeting <const> = "hi"
print(greeting)
