-- A tight numeric for-loop with no closures: every local in this file
-- is read/written only by the surrounding scope, so escape analysis
-- should keep them out of $Box and the generated WAT should not
-- contain any struct.new $Box / struct.get $Box $v / struct.set $Box $v.
local total = 0
for i = 1, 1000 do
  total = total + i
end
print(total)  -- 500500
