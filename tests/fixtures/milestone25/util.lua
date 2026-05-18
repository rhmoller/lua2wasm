-- Milestone 25 test module: a leaf module returning a table.
local M = {}

function M.shout(s)
  return string.upper(s) .. "!"
end

function M.dup(s)
  return s .. s
end

return M
