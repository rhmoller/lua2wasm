-- string.format rejects invalid directives per Lua's scanformat, matching
-- lua5.5: %q with any modifier; precision on %c; %% with a modifier; the
-- non-conversion %F; unknown conversions; C length modifiers; >2-digit
-- width/precision; and %p with bad flags/precision. Code-review #12.
local function f(spec, arg) local ok = pcall(string.format, spec, arg); return spec .. "=" .. (ok and "accept" or "reject") end
print(f("%-q", "hi"))
print(f("%5q", "hi"))
print(f("%.3c", 65))
print(f("%5%"))
print(f("%-%"))
print(f("%F", 3.5))
print(f("%ld", 5))
print(f("%n", 5))
print(f("%100d", 5))
print(f("%.100f", 5))
print(f("%+p", {}))
print(f("%0p", {}))
print(f("%.3p", {}))
-- valid directives still work
print(f("%+d", 5), f("%#x", 255), f("%-8.3f", 3.14159), f("%5c", 65), f("%.3s", "abcdef"), f("%q", "a"), f("%-p", {}) ~= "%-p=accept" and "p-ok" or "p-ok")
