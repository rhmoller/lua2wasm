-- Tables (and functions) used as table keys: identity-based, so two
-- distinct tables are distinct keys even when structurally equal.
local a, b = {}, {}
local m = {}
m[a] = "a"; m[b] = "b"
print(m[a], m[b], m[a] == m[b])        -- a  b  false
m[a] = "A"                              -- overwrite
print(m[a], m[b])                      -- A  b
local cnt = 0
for k, v in pairs(m) do cnt = cnt + 1 end
print(cnt)                             -- 2
m[a] = nil                             -- delete a table key
print(m[a], m[b])                      -- nil  b
-- a function as a key works too
local f = function() end
m[f] = "fn"
print(m[f])                            -- fn
-- many distinct table keys round-trip
local ks, t = {}, {}
for i = 1, 500 do ks[i] = {}; t[ks[i]] = i end
local s = 0
for i = 1, 500 do s = s + t[ks[i]] end
print(s)                              -- 125250
