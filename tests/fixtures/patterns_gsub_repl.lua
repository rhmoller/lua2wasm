-- string.gsub with table and function repl (step 8 of milestone 20).
-- Replacement value can be:
--   string   — interpreted via %N (handled by step 7)
--   table    — t[capture_or_match]; nil/false ⇒ keep original
--   function — f(captures); return string/number/nil/false
-- A returned nil or false keeps the original match. Anything else
-- (boolean true, table, function, ...) raises.

-- table repl
local map = {a = "one", b = "two", c = "three"}
print(string.gsub("abc", "%a", map))                       -- onetwothree   3

-- table with missing keys — original kept.
print(string.gsub("abXYZ", "%a", {a = "1", b = "2"}))      -- 12XYZ        5

-- table keyed by first capture.
print(string.gsub("a=1 b=2 c=3", "(%a)=%d", {a="A", b="B"}))
                                                            -- A B c=3      3

-- function repl, simple.
print(string.gsub("hello", "%a", function(c) return string.upper(c) end))
                                                            -- HELLO         5

-- function returning nil keeps original.
print(string.gsub("abc", "%a", function(c) return c == "b" and "B" or nil end))
                                                            -- aBc           3

-- function returning false also keeps original.
print(string.gsub("xyz", "%a", function() return false end))
                                                            -- xyz           3

-- function with multiple captures.
print(string.gsub("a=1 b=2", "(%a)=(%d)",
                  function(k, v) return k .. ":" .. v end))
                                                            -- a:1 b:2       2

-- function returning a number.
print(string.gsub("aaa", "a", function() return 42 end))
                                                            -- 424242        3

-- repl arg of the wrong type raises (catchable).
print(pcall(string.gsub, "x", "x", true))                  -- false ...

-- string repl still works (regression).
print(string.gsub("hello", "l", "L"))                      -- heLLo         2
