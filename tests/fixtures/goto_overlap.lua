-- A block with a backward-target label BEFORE a forward-target label.
-- Old codegen rejected this as "overlapping forward+backward labels"
-- because it tried to wrap forward blocks around backward loops in the
-- wrong nesting order. The dispatch lowering handles it uniformly.
local x = 0
do
  ::top::
  x = x + 1
  if x >= 3 then goto done end
  goto top
  ::done::
end
print(x)
