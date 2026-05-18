-- string.gsub with string replacement (step 7 of milestone 20).
-- repl is a string; %0 = whole match, %1..%9 = captures, %% = '%'.

print(string.gsub("hello world", "o", "0"))               -- hell0 w0rld   2
print(string.gsub("hello world", "o", "0", 1))            -- hell0 world    1
print(string.gsub("abc", "%a", "X"))                      -- XXX            3
print(string.gsub("hi 42, bye 7", "%d+", "N"))            -- hi N, bye N    2

-- %1 references the first capture.
print(string.gsub("foo bar baz", "(%a+)", "[%1]"))        -- [foo] [bar] [baz]   3

-- %0 is the whole match (also %1 when the pattern has no captures).
print(string.gsub("hello", "%a+", "X%0Y"))                -- XhelloY        1
print(string.gsub("hello", "%a+", "X%1Y"))                -- XhelloY        1

-- Position capture interpolation: emitted as a decimal-int string.
print(string.gsub("ab", "()(.)", "%1:%2,"))               -- 1:a,2:b,       2

-- %% emits a literal '%'.
print(string.gsub("test", "%a", "%%"))                    -- %%%%           4

-- No match: subject returned verbatim, count is 0.
print(string.gsub("abc", "x", "-"))                       -- abc            0

-- Empty match yields one insertion per position plus the trailing one.
print(string.gsub("abc", "x?", "-"))                      -- -a-b-c-        4
print(string.gsub("",    "x?", "-"))                      -- -              1

-- Anchored gsub only ever matches once (at position 1).
print(string.gsub("xxxx", "^x", "y"))                     -- yxxx           1

-- '%X' where X is a non-digit non-'%' drops the '%' and keeps X.
print(string.gsub("hi", "%a", "X%nY"))                    -- XnYXnY         2
