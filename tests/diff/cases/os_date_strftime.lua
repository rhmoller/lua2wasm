-- os.date strftime specifiers, forced to UTC with '!' so they are
-- deterministic. Reference uses the C locale for weekday/month names.
print(os.date("!%Y-%m-%d %H:%M:%S", 0))      -- 1970-01-01 00:00:00
print(os.date("!%a %A %b %B", 0))            -- Thu Thursday Jan January
print(os.date("!%y %p %I %j %w", 0))         -- 70 AM 12 001 4
print(os.date("!%c", 0))                     -- Thu Jan  1 00:00:00 1970
print(os.date("!%x %X", 0))                  -- 01/01/70 00:00:00
print(os.date("!%%lit%%"))                   -- %lit%

-- a non-epoch UTC time (2001-09-09 01:46:40)
print(os.date("!%Y-%m-%d %H:%M:%S", 1000000000))
print(os.date("!%A, %d %B %Y", 1000000000))
print(os.date("!%I:%M:%S %p", 1000000000))   -- 12-hour clock
print(os.date("!%I %p", 46805))              -- 13:00:05 -> 01 PM

-- the "*t" table form
local tab = os.date("!*t", 1000000000)
print(tab.year, tab.month, tab.day, tab.hour, tab.min, tab.sec,
      tab.wday, tab.yday, tab.isdst)
