-- Error semantics of <close>: __close receives the in-flight error object;
-- a __close that itself raises does not stop the remaining closes, and the
-- newest error is what propagates. No __close runs twice.
local log = {}
local function note(s) log[#log + 1] = s end
local function ok(tag) return setmetatable({}, {__close = function(_, e)
  note("close " .. tag .. " err=" .. tostring(e)) end}) end
local function boom(tag) return setmetatable({}, {__close = function()
  note("close " .. tag .. " (raises)"); error(tag .. "-fail") end}) end

-- (1) error in the body: closed in reverse order, each gets the error object.
log = {}
local r1 = table.pack(pcall(function()
  local a <close> = ok("a")
  local b <close> = ok("b")
  error("body-boom")
end))
note("-> ok=" .. tostring(r1[1]) .. " err=" .. tostring(r1[2]))
print(table.concat(log, " | "))

-- (2) a __close that raises: later closes still run and see the NEW error;
-- the newest error propagates. Each __close runs exactly once.
log = {}
local r2 = table.pack(pcall(function()
  local a <close> = ok("a")
  local b <close> = boom("b")
  local c <close> = ok("c")
end))
note("-> ok=" .. tostring(r2[1]) .. " err=" .. tostring(r2[2]))
print(table.concat(log, " | "))

-- (3) a __close raising during a normal return turns the return into an error,
-- closing the rest; no double close.
log = {}
local function f()
  local a <close> = ok("a")
  local b <close> = boom("b")
  return 42
end
local r3 = table.pack(pcall(f))
note("-> ok=" .. tostring(r3[1]) .. " err=" .. tostring(r3[2]))
print(table.concat(log, " | "))
