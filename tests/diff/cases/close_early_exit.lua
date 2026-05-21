-- A <close> variable's __close handler must run on EVERY exit from its block,
-- in reverse declaration order: normal fall-through, return, break, goto out
-- of the block, and error unwinding. We previously closed only on natural
-- block exit.
local log
local function mk(tag) return setmetatable({}, {__close = function() log[#log + 1] = tag end}) end
local function run(label, f) log = {}; pcall(f); print(label, table.concat(log, ",")) end

run("normal", function()
  local a <close> = mk("a")
  local b <close> = mk("b")
end)
run("return", function()
  local a <close> = mk("a")
  local b <close> = mk("b")
  do return end
end)
run("break", function()
  for _ = 1, 1 do
    local c <close> = mk("c")
    break
  end
end)
run("goto", function()
  do
    local d <close> = mk("d")
    goto done
  end
  ::done::
end)
run("error", function()
  local e <close> = mk("e")
  error("boom")
end)
