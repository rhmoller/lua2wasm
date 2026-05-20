-- Files, in your browser! io.open / io.lines / io.type read and write a
-- virtual filesystem (powered by just-bash) that PERSISTS across Runs.
-- Click Run a few times and watch the visit counter climb.

local counter = "/demo/visits.txt"

-- Read the previous count. io.open returns nil (not an error) when the
-- file is missing, so the very first Run simply starts from zero.
local n = 0
local f = io.open(counter, "r")
if f then
  n = tonumber(f:read("a")) or 0
  f:close()
end
n = n + 1

-- Write the new count back. "w" truncates; assert turns a failed open
-- into an error carrying the host's message.
local out = assert(io.open(counter, "w"))
out:write(tostring(n))
out:close()
print("You have run this program " .. n .. " time(s).")

-- A second file shows the rest of the API: multi-arg write, io.lines,
-- byte-accurate read + seek, io.type, and os.remove.
local notes = "/demo/notes.txt"
local g = assert(io.open(notes, "w"))
g:write("buy milk\n")
g:write("write a compiler\n", "learn Lua\n")   -- :write takes many args
g:close()

print("\nnotes.txt, line by line:")
for line in io.lines(notes) do
  print("  - " .. line)
end

local r = assert(io.open(notes, "r"))
print("\nfirst 8 bytes:", r:read(8))        -- "buy milk"
r:seek("set", 0)                            -- rewind to the start
print("after rewind: ", r:read("l"))        -- "buy milk" (whole first line)
print("io.type open: ", io.type(r))         -- file
r:close()
print("io.type closed:", io.type(r))        -- closed file

os.remove(notes)
print("\nremoved notes.txt — visits.txt stays. That's the persistence!")
