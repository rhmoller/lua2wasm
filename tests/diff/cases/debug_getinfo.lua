-- debug.getinfo. Fields like nparams / nups / isvararg / linedefined require
-- per-function debug metadata that an AOT compiler with no bytecode does not
-- retain. Captured as a gap (a partial getinfo returning what/source/
-- currentline is feasible, but the full record below is not).
local function foo(a, b) return debug.getinfo(1, "nSlu") end
local i = foo(1, 2)
print(i.what, i.nparams, i.isvararg, i.nups)
