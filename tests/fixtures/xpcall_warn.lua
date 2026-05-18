-- xpcall(f, msgh [, ...]) — like pcall but msgh handles the error.
-- warn(...)              — emits "Lua warning: " + concat to stderr.
-- error(msg [, level])   — level arg accepted (ignored for v1).

-- xpcall: error path. msgh's return value becomes the second result.
print(xpcall(function() error("boom") end,
             function(e) return "handled: " .. e end))     -- false   handled: boom

-- xpcall: success path forwards results.
print(xpcall(function(a, b) return a + b end,
             function(e) return e end, 3, 4))              -- true    7

-- xpcall: multiple returns survive.
print(xpcall(function() return 1, 2, 3 end,
             function(e) return e end))                    -- true    1    2    3

-- xpcall: handler that itself throws — its error replaces the original.
print(xpcall(function() error("first") end,
             function(e) error("from handler") end))       -- false   from handler

-- xpcall: handler is a closure that can capture state.
local count = 0
local _ = xpcall(function() error("x") end,
                 function(e) count = count + 1 end)
print(count)                                               -- 1
local ok, err = xpcall(function() error("x") end,
                       function(e) return "h" .. count .. ":" .. e end)
print(ok, err)                                             -- false   h1:x

-- error(msg, level) — level is accepted and currently ignored.
print(pcall(function() error("no level") end))             -- false   no level
print(pcall(function() error("level 0", 0) end))           -- false   level 0
print(pcall(function() error("level 2", 2) end))           -- false   level 2

-- warn — single arg, multiple args, control messages.
warn("hello")
warn("a", "b", "c")
warn("@off")    -- accepted silently
warn("@on")     -- accepted silently
warn("after")
warn(123, " is a number")
