-- collectgarbage("count") should report live memory in KB and grow as
-- allocations accumulate. lua2wasm has no managed GC to account for (the host
-- owns memory), so "count" is a stub and cannot reflect live size. Captured
-- as an architectural gap.
collectgarbage()
local before = collectgarbage("count")
local t = {}
for i = 1, 2000 do t[i] = {} end
local after = collectgarbage("count")
print(type(before) == "number", after > before)
