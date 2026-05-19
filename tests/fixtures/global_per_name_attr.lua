-- Per-name attribute on a `global` declaration: `global X<const>, Y`.
-- The parser must accept the suffix attribute on each name; full const
-- enforcement on globals is not implemented yet.
global X<const>, Y, Z<const>
X = 1
Y = 2
Z = 3
print(X, Y, Z)
