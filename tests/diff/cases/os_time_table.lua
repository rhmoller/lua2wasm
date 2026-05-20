-- os.time(table) builds a unix timestamp from a LOCAL date table. The
-- round-trip os.time(os.date("*t", T)) == T is timezone-independent, as is
-- reading the fields back, so these assertions are portable.
for _, T in ipairs({0, 1000000000, 1234567890, -86400, 946684800}) do
  print(os.time(os.date("*t", T)) == T)
end

-- explicit fields read back unchanged
local t = os.time({year = 2020, month = 6, day = 15, hour = 12, min = 30, sec = 45})
local d = os.date("*t", t)
print(d.year, d.month, d.day, d.hour, d.min, d.sec)   -- 2020 6 15 12 30 45

-- hour defaults to 12 (min/sec to 0)
local d2 = os.date("*t", os.time({year = 2000, month = 1, day = 1}))
print(d2.hour, d2.min, d2.sec)                         -- 12 0 0

-- required fields and a non-table argument raise catchable errors
local function bad(...) return (pcall(os.time, ...)) end
print(bad({year = 2000, month = 1}))   -- false  (day missing)
print(bad({}))                         -- false  (year missing)
print(bad(5))                          -- false  (table expected)

print(type(os.time()))                 -- number (no-arg form still works)
