-- Milestone 25 test module: a module that itself requires another.
local util = require("util")

local M = {}

function M.banner(s)
  return util.shout("=== " .. s .. " ===")
end

function M.echo2(s)
  return util.dup(s)
end

return M
