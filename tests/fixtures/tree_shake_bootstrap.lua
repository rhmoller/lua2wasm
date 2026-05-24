-- A table-free program: it constructs no tables and writes no globals, so
-- under --tree-shake its _G and the math/string library tables are populated
-- by $tab_bootstrap_set and the table write path is dead-code eliminated.
-- Reading the builtins/libraries back exercises the hash index that the
-- bootstrap helper builds incrementally (with its own grow + rehash).
print(math.floor(math.sqrt(50)))
print(("abc"):upper(), string.rep("x", 3))
print(type(print), tostring(42), select("#", 10, 20, 30))
