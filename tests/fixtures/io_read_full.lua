-- io.read — full format coverage. Stdin is supplied by the test driver.
--
-- Input (literal):
--   first
--   second
--   third
--   42 3.14
--   ABCDEextra
--   tail

-- Default (no args) is "l".
print(io.read())                    -- first

-- "l" and "L".
print(io.read("l"))                 -- second
print("[" .. io.read("L") .. "]")   -- [third\n]

-- "n" parses one number; whitespace before the number is skipped.
-- Two consecutive "n"s consume "42" and "3.14".
print(io.read("n"), math.type(io.read("n")))    -- 42   float

-- After "n", the rest of that line is still on the cursor.
-- io.read("l") returns "" (empty leftover; reaches \n immediately).
print("[" .. io.read("l") .. "]")   -- []

-- Integer count reads exactly N bytes.
print(io.read(5))                   -- ABCDE

-- "L" picks up "extra\n" through the newline.
print("[" .. io.read("L") .. "]")   -- [extra\n]

-- "a" returns all remaining (and "" at EOF, never nil).
print("[" .. io.read("a") .. "]")   -- [tail]
print("[" .. io.read("a") .. "]")   -- []

-- After EOF, line modes and "n" return nil.
print(io.read("l"))                 -- nil
print(io.read("n"))                 -- nil
print(io.read(10))                  -- nil
