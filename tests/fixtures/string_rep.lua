-- string.rep(s, n [, sep]) — n copies of s, optionally joined by sep.

print(string.rep("ab", 3))            -- ababab
print(string.rep("ab", 3, "-"))       -- ab-ab-ab
print(string.rep("ab", 1))            -- ab
print(string.rep("ab", 1, "-"))       -- ab     (no sep with one copy)
print(string.rep("ab", 0))            -- (empty)
print(string.rep("ab", 0, "-"))       -- (empty)
print(string.rep("ab", -5))           -- (empty) — negative n
print(string.rep("", 5))              -- (empty)
print(string.rep("", 5, "-"))         -- ----   (sep still applies)
print(string.rep("x", 5))             -- xxxxx
print(string.rep("longer", 2, "==="))-- longer===longer
print(#string.rep("abc", 100))        -- 300 (no sep)
print(#string.rep("abc", 100, ","))   -- 399 (99 separators)
