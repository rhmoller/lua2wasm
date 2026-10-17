-- Lua 5.5 strict globals: once a chunk uses any `global` declaration, every
-- other global (read or write, including builtins like print) must also be
-- declared, else it is a *compile-time* error. The harness compares the
-- rejection by line and message; tests/test_compile_checks.sh covers the rest
-- of the rules.
global x = 1
y = 2
print(x, y)
