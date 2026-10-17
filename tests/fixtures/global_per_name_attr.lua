-- Per-name attributes on a `global` declaration: `global X<const>, Y` makes
-- X and Z read-only (assigning them is a compile-time error, see
-- tests/test_compile_checks.sh) and leaves Y read-write.
X, Y, Z = 1, 2, 3
global print
global X<const>, Y, Z<const>
Y = X + Z
print(X, Y, Z)
