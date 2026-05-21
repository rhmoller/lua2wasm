-- Lua 5.5 strict globals: once a chunk uses any `global` declaration, every
-- other global (read or write, including builtins like print) must also be
-- declared, else it is a *compile-time* error. lua2wasm keeps Lua-traditional
-- implicit globals, so it accepts this chunk. This is compile-error parity:
-- the differential harness can only record it as <compile-fail> vs reference's
-- diagnostic, so it stays captured here rather than turning green.
global x = 1
y = 2
print(x, y)
