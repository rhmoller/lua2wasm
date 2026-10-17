-- Lua 5.5 `global` declarations with <const>. `global <const> *` makes every
-- name not declared otherwise a read-only global; `global <const> a, b`
-- declares read-only globals and `global x, y` read-write ones. Read-only
-- only forbids assigning through the name (a compile-time error, see
-- tests/test_compile_checks.sh); reading is fine.
a, b = 1, 2      -- before any declaration: ordinary globals
global <const> *
global <const> a, b
global x, y
x = 10
y = a + b + x
print(a, b, x, y, type(print))
