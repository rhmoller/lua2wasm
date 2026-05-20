-- table.concat accepts only string/number elements. A boolean or table
-- element must raise a *catchable* error — it must NOT be silently
-- tostring'd into the result. Semantic check only (exact wording, the
-- offending type/index, and chunk name are intentionally not asserted).
local function probe(t)
  local ok, err = pcall(table.concat, t, ",")
  if ok then
    print("ok", err)
  else
    print("err", type(err), err:find("concat", 1, true) ~= nil)
  end
end
probe({1, 2, 3})           -- ok 1,2,3
probe({"a", "b"})          -- ok a,b
probe({true})              -- err string true
probe({{}})                -- err string true
probe({1, false, 3})       -- err string true
-- valid mixed types and the empty range still produce strings
print(table.concat({1, "x", 2.5}, "-"))      -- 1-x-2.5
print("[" .. table.concat({}, ",") .. "]")   -- []
