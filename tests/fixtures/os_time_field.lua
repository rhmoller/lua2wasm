-- os.time with an out-of-range or fractional date field is a CATCHABLE
-- error (was an uncatchable "float unrepresentable in integer range" trap).
local function err(tbl)
  local ok, e = pcall(os.time, tbl)
  return ok, type(e) == "string"
end
print(err({ year = 1e20, month = 1, day = 1 }))   -- false  true (out of range)
print(err({ year = 2020.5, month = 1, day = 1 })) -- false  true (fractional)
print(err({ year = "x", month = 1, day = 1 }))    -- false  true (non-number)
print(err({ month = 1, day = 1 }))                -- false  true (missing year)
-- a valid table still works and round-trips through os.date
local ok = pcall(os.time, { year = 2020, month = 6, day = 15 })
print(ok)                                         -- true
local t = os.time({ year = 2020, month = 6, day = 15, hour = 12, min = 0, sec = 0 })
print(os.date("%Y-%m-%d", t))                     -- 2020-06-15
