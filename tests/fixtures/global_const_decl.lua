-- Lua 5.5 `global` declaration syntax.
-- `global <const> *` is the "wildcard" form (all unlisted globals
-- become read-only); we accept-and-ignore it.
-- `global <const> name, name` declares specific names; const semantics
-- are not enforced yet — parser must just accept the syntax.
global <const> *
global <const> a, b
global x, y
a = 1
b = 2
x = 10
y = 20
print(a, b, x, y)
