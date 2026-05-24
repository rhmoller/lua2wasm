-- KNOWN GAPS (code-review #12, partial): string.format flag/conversion
-- validation is incomplete. lua5.5 rejects all of these; we accept them ->
-- xfail. The flag-on-numeric cases ARE fixed (see format_flag_validity).
-- Remaining: %q rejects all modifiers; per-conversion width/precision (%c);
-- %p flag validation; %% with modifiers; %F; C length modifiers (%ld).
local function f(spec, arg) local ok = pcall(string.format, spec, arg); return spec .. "=" .. (ok and "accept" or "reject") end
print(f("%-q", "hi"))
print(f("%.3c", 65))
print(f("%+p", {}))
print(f("%5%"))
print(f("%F", 3.5))
print(f("%ld", 5))
