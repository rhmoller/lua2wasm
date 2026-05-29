-- A program that observes no runtime state: only literals, locals, and control
-- flow — no globals, builtins, operators, indexing, calls, or for-loops. Its
-- return value is discarded by $main, so $stdlib_init is dead and the codegen
-- gate drops the call (letting DCE cascade-remove the whole runtime). It prints
-- nothing; the test asserts the WAT shape and a clean exit, not output.
local x = 10
local y = x
if y then
    local z = y
    y = z
end
return y
