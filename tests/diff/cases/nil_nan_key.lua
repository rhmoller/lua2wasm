-- A nil or NaN table key raises ("table index is nil"/"NaN") on assignment and
-- in a constructor, not silently stored. rawset already enforced this; the
-- t[k]=v and {[k]=v} paths did not. Fuzzer-found (code-review finding #8).
local function bad(f) local ok, e = pcall(f); return ok, type(e) end
print(bad(function() local t = {}; t[nil] = 1 end))
print(bad(function() local t = {}; t[0/0] = 1 end))
print(bad(function() return {[nil] = 1} end))
print(bad(function() local k = 0/0; return {[k] = 1} end))
print(bad(function() rawset({}, nil, 1) end))
-- valid keys unaffected: nil VALUE (delete) is fine, integral-float normalizes
print(pcall(function() local t = {1,2,3}; t[2] = nil; return tostring(t[1])..","..tostring(t[2])..","..tostring(t[3]) end))
print(pcall(function() local t = {}; t[2.0] = "x"; return tostring(t[2]) end))
