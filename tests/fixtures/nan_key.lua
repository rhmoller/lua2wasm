-- NaN key behavior pin-test.
-- $lua_eq_raw uses f64.eq, which is false for NaN==NaN. So a NaN
-- key is inserted but can never be retrieved. (Real Lua 5.4 raises
-- "table index is NaN" on insertion; matching that is future work.)
local nan = 0.0 / 0.0
print(nan ~= nan)   -- true
local t = {}
t[nan] = "set"
print(t[nan])       -- nil (irrecoverable)
print(t[1])         -- nil (unrelated key)
