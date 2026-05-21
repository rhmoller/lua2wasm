local log = {}
local t = setmetatable({10,20,30}, {__newindex = function(tt,k,v) log[#log+1] = "ni:"..k end})
t[2] = 99   -- key 2 present (array part): __newindex must NOT fire, raw overwrite
print(t[2], #log)            -- 99  0
t[5] = 50   -- key 5 absent: __newindex fires; default handler doesn't rawset
print(t[5], #log, log[1])    -- nil  1  ni:5
