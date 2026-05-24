-- A <close> variable declared in a repeat body stays in scope for the until
-- condition and is closed AFTER the condition is evaluated (Lua §3.3.5). The
-- condition here observes a flag that __close sets, so close-before-cond and
-- close-after-cond produce different traces and iteration counts.
local trace = {}
local done = false
repeat
  local x <close> = setmetatable({ tag = "x" }, {
    __close = function(self) done = true; trace[#trace + 1] = "close " .. self.tag end,
  })
  trace[#trace + 1] = "body"
until (function() trace[#trace + 1] = "cond(" .. tostring(done) .. ")"; return done end)()
print(table.concat(trace, " "))

-- The condition can still read the (not-yet-closed) variable directly.
local n = 0
repeat
  local g <close> = setmetatable({ v = n }, { __close = function() end })
  n = n + 1
until g.v >= 2
print("stopped at n=" .. n)
