-- Functions / control-flow / misc corners that already match reference Lua 5.5.
print(select('#'), select('#', 1, 2, 3), select(2, 'a', 'b', 'c'), select(-1, 'a', 'b', 'c'))
local a, b, c = 1, 2 print(a, b, c)
print(1 and 2, nil and 2, false or "x", nil or nil, 0 and "zero is true")
print(not nil, not false, not 0, not "")
do local i = 1 ::top:: if i <= 3 then io.write(i) i = i + 1 goto top end print() end
local cnt = 0 for i = 1, 3 do for j = 1, 3 do if j == 2 then break end cnt = cnt + 1 end end print(cnt)
local i = 0 repeat i = i + 1 until i >= 3 print(i)
local ok, e = pcall(function() error({ code = 7 }) end) print(ok, type(e), e.code)
local ok2, e2 = pcall(function() error("msg", 0) end) print(ok2, e2)
print(pcall(function() return assert(42, "unused") end))
print(xpcall(function() error("x") end, function(m) return "handled" end))
print(rawequal(1, 1), rawequal({}, {}), rawlen("abc"), rawlen({ 1, 2, 3 }))
print(type(nil), type(true), type(1), type(1.0), type("s"), type({}), type(print))
