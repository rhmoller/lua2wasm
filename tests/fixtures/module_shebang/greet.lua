#!/usr/bin/env lua
-- A module that is also runnable as a script (hence the shebang).
local M = {}
function M.hello(name) return "hello, " .. name end
return M
