-- Tail call whose trailing argument is a multi-value call. Regression:
-- emit_tail_call kept the callee in $tmp_any, which a method-call argument
-- (e.g. s:gmatch(...)) overwrote with its receiver, so the tail call then
-- tried to call a non-function.
local function arr(...) local t = {} for x in ... do t[#t+1] = x end return t end
local function split(s) return arr(s:gmatch("%S+")) end          -- method-call arg
print(table.concat(split("a b c d"), ","))                       -- a,b,c,d

local function count(...) return select("#", ...) end
local function f3() return 1, 2, 3 end
local function viaplaincall(s) return count(string.gmatch(s, "%S+")) end
print(viaplaincall("x y"))                                       -- 1 (one iterator)
print((function() return count(f3()) end)())                     -- 3
print((function() return count(0, f3()) end)())                  -- 4
print((function(t) return count(table.unpack(t)) end)({9,8,7}))  -- 3

-- callee that is itself an expression, trailing multi-value arg
local M = {}
function M.j(...) return select("#", ...) end
print((function(s) return M.j(s:gmatch(".")) end)("ab"))         -- 1
