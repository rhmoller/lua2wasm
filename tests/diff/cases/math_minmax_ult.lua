-- math.min/math.max use the full < operator: numbers compare numerically,
-- strings lexically, and the *original* winning argument is returned (no
-- coercion). A non-comparable mix raises a catchable "attempt to compare"
-- error instead of an uncatchable trap. math.ult coerces integer-valued
-- strings and rejects non-integers / non-numbers with a catchable error.
print(math.max(1, 5, 3), math.min(1, 5, 3))               -- 5  1
print(math.max("a", "c", "b"), math.min("a", "c", "b"))   -- c  a  (lexical)
print(math.type(math.max("1", "2")))                      -- nil (stayed a string)

local function err_has(f, word)
  local ok, e = pcall(f)
  print(ok, type(e) == "string" and e:find(word, 1, true) ~= nil)
end
err_has(function() return math.max(1, {}) end, "compare")      -- false true
err_has(function() return math.min("x", 1) end, "compare")     -- false true

print(math.ult(1, 2), math.ult(-1, 1))                    -- true  false
print(math.ult("1", "2"))                                 -- true  (string coerced)
err_has(function() return math.ult(1.5, 2) end, "integer")          -- false true
err_has(function() return math.ult({}, 1) end, "number expected")   -- false true
