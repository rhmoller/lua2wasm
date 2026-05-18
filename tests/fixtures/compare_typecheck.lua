-- Relational operators <, <=, >, >= accept:
--   - two numbers (int or float, freely mixed)
--   - two strings (byte-wise lexicographic)
-- Anything else (incl. cross-type number-vs-string) raises a catchable error.
-- (TODO: __lt / __le metamethods.)

-- Number comparisons.
print(1 < 2)             -- true
print(2 < 1)             -- false
print(1 <= 1)            -- true
print(1 < 1.5)           -- true
print(1.5 > 1)           -- true
print(1.0 == 1)          -- true   (cross-int/float equality is fine)

-- String comparisons (lexicographic, byte-wise).
print("a" < "b")         -- true
print("b" < "a")         -- false
print("a" <= "a")        -- true
print("a" < "ab")        -- true   (prefix shorter)
print("ab" < "b")        -- true   (b < ab differ at idx 0)
print("Z" < "a")         -- true   (uppercase ASCII before lowercase)

-- == across types: always false (no metamethod), no error.
print(1 == "1")          -- false
print(1 == true)         -- false
print(nil == false)      -- false

-- < across types: error (catchable).
print(pcall(function() return 1 < "2" end))
print(pcall(function() return "a" < 1 end))
print(pcall(function() return 1 < nil end))
print(pcall(function() return nil < 1 end))
print(pcall(function() return {} < {} end))

-- > and >= follow the same rules.
print(pcall(function() return 1 > "x" end))
print(pcall(function() return "x" >= 1 end))
