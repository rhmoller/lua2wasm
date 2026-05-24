-- next() with a key that is not in the table raises a catchable
-- "invalid key to 'next'" (reference luaH_next), rather than silently
-- restarting iteration. Assertions avoid the unspecified hash order.
local t = {a = 1, b = 2, c = 3}
local ok, e = pcall(next, t, "nope")
print(ok, type(e) == "string" and e:match("invalid key") ~= nil)
-- valid iteration is unaffected: pairs visits every entry exactly once
local sum, n = 0, 0
for _, v in pairs(t) do sum = sum + v; n = n + 1 end
print(sum, n)
-- a manual next() walk from nil reaches the end without error
local count, key = 0, nil
repeat
  key = next(t, key)
  if key ~= nil then count = count + 1 end
until key == nil
print(count)
print(next({}))
