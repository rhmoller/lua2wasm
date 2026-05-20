-- Indexing a non-table/non-string value raises a *catchable* error whose
-- message mentions "index". It used to be miscategorized as a call error
-- ("attempt to call a non-function value"). Semantic check only — exact
-- wording / variable name / chunk name are intentionally not asserted.
local function probe(f)
  local ok, err = pcall(f)
  print(ok, type(err), err:find("index", 1, true) ~= nil)
end
probe(function() local t = nil; return t.x end)
probe(function() local t = nil; return t["k"] end)
probe(function() local n = 5; return n.field end)
probe(function() return ({}).a.b end)   -- ({}).a is nil, then .b on nil
probe(function() local t = nil; t.z = 1 end)  -- write path too
