-- table.insert / table.remove validate their position argument and arity
-- (reference luaL_argcheck). Out-of-range positions and wrong arity raise
-- catchable errors instead of silently succeeding (or trapping). Semantic
-- check: error status + that the message mentions bounds/arguments.
local function ck(...)
  local ok, e = pcall(...)
  local m = tostring(e)
  return ok, (m:find("bounds", 1, true) or m:find("number of arg", 1, true)) ~= nil
end

-- insert: position must be in [1, #t+1]; exactly 2 or 3 args
print(ck(table.insert, {1, 2, 3}, 5, "x"))   -- false true  (> #t+1)
print(ck(table.insert, {1, 2, 3}, 0, "x"))   -- false true  (< 1)
print(ck(table.insert, {1, 2, 3}, 1, 2, 3))  -- false true  (4 args)
print(ck(table.insert, {1, 2, 3}))           -- false true  (1 arg)

-- remove: an explicit pos must be in [1, #t+1]
print(ck(table.remove, {1, 2, 3}, 5))        -- false true
print(ck(table.remove, {1, 2, 3}, 0))        -- false true

-- valid operations are unchanged
local a = {1, 2, 3}; table.insert(a, 2, "x"); print(table.concat(a, ","))   -- 1,x,2,3
local b = {1, 2, 3}; table.insert(b, 4, "e"); print(table.concat(b, ","))   -- 1,2,3,e
local c = {1, 2, 3}; table.insert(c, "z");    print(table.concat(c, ","))   -- 1,2,3,z
local d = {1, 2, 3}; print(table.remove(d), table.concat(d, ","))           -- 3  1,2
local e = {1, 2, 3}; print(table.remove(e, 1), table.concat(e, ","))        -- 1  2,3
print(table.remove({}), table.remove({}, 0))                                -- nil nil
print(table.remove({1, 2, 3}, 4))                                           -- nil (#t+1)
