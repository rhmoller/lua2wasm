-- A block with labels (forcing dispatch-table lowering) where a
-- captured local declared in segment 0 (before the label) is read
-- DIRECTLY in segment 1 (after the label) — mirroring the pattern
-- locals.lua's final do-block uses with `::endloop::`. The wasm
-- validator can't statically prove segment 0 ran before segment 1
-- (br_table can target either), so without eager-initialising every
-- captured local at function entry the module is rejected with
-- "non-nullable local's sets must dominate gets".
local function f()
  local count = 0
  local incr = function() count = count + 1 end   -- captures count
  for _ = 1, 3 do
    incr()
    if count >= 2 then goto done end
  end
  ::done::
  return count   -- direct read of captured-and-boxed count in segment 1
end
print(f())   -- incr fires until count >= 2 → 2
