-- A generic-for's iterator explist yields a 4th "closing" value that is
-- to-be-closed (Lua §3.3.5): its __close runs when the loop ends — on normal
-- completion, on break, and on an error — and a non-closable closing value is
-- rejected. nil/false (the common pairs/ipairs case) is accepted, never closed.
local function range(n, closing)
  local i = 0
  return function() i = i + 1; if i <= n then return i end end, nil, nil, closing
end
local function C(tag)
  return setmetatable({}, { __close = function(_, e)
    print("close " .. tag .. " err=" .. tostring(e)) end })
end

print("-- normal completion --")
for x in range(2, C("a")) do print("x=" .. x) end

print("-- break closes the closing value --")
for x in range(9, C("b")) do print("x=" .. x); if x == 1 then break end end

print("-- error in body: closing runs with the error, then it propagates --")
local ok, err = pcall(function()
  for x in range(9, C("c")) do error("body boom") end
end)
print("ok=" .. tostring(ok) .. " is_string=" .. tostring(type(err) == "string"))

print("-- nil closing value (pairs): nothing to close --")
for k in pairs({ 10, 20 }) do print("k=" .. k) end

print("-- non-closable closing value is a catchable error --")
print(pcall(function() for x in (function() end), nil, nil, 42 do end end))

print("-- nested for-loops close inner then outer --")
for a in range(1, C("outer")) do
  for b in range(1, C("inner")) do print("a=" .. a .. " b=" .. b) end
end
