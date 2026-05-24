-- KNOWN GAP (code-review #9): we do not detect an inconsistent comparator.
-- lua5.5's partition heuristic raises "invalid order function for sorting" on
-- this 12-element array; we silently return a permutation -> xfail. A faithful
-- fix needs a Hoare-partition out-of-bounds port. NOTE: a naive cmp(x,x)
-- reflexivity check is WRONG (reverted 45ee5fc) — lua5.5 ACCEPTS the same
-- comparator on small/sorted arrays, so detection is array-size-dependent.
local ok, e = pcall(table.sort, { 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }, function() return true end)
print(ok, ok or (tostring(e):match("invalid order") and "invalid-order" or "other"))
