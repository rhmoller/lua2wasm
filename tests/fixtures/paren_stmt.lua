-- A statement whose prefix-expression starts with `(`. Both the leading
-- `;` and the bare `(…)` forms must parse — they are common in the
-- official test suite's "skip if T is missing" guards.
local function greet(name) print("hello " .. name) end
local Message

if not Message then
  (Message or greet)("world")
end

local Message2
;(Message2 or greet)("again")
