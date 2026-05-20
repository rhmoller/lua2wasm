-- tonumber(v [, base]) — per Lua 5.5 manual §6.1.

-- Numbers pass through unchanged when no base given.
print(tonumber(42))            -- 42
print(tonumber(3.14))          -- 3.14
print(tonumber(0))             -- 0

-- Strings: decimal integer.
print(tonumber("42"))          -- 42
print(tonumber("-7"))          -- -7
print(tonumber("+5"))          -- 5

-- Strings: float forms.
print(tonumber("3.14"))        -- 3.14
print(tonumber("-3.14"))       -- -3.14
print(tonumber("1e3"))         -- 1000.0
print(tonumber("1.5E-2"))      -- 0.015
print(tonumber(".5"))          -- 0.5
print(tonumber("5."))          -- 5.0

-- Strings: hex integer.
print(tonumber("0x10"))        -- 16
print(tonumber("0XFF"))        -- 255
print(tonumber("-0x10"))       -- -16

-- Leading and trailing whitespace is trimmed.
print(tonumber("  42  "))      -- 42
print(tonumber("\t3.14\n"))    -- 3.14

-- Invalid: empty, all whitespace, garbage, mid-string garbage.
print(tonumber(""))            -- nil
print(tonumber("   "))         -- nil
print(tonumber("xyz"))         -- nil
print(tonumber("42abc"))       -- nil
print(tonumber("3.14.15"))     -- nil

-- Non-strings without a base: nil.
print(tonumber(nil))           -- nil
print(tonumber(true))          -- nil
print(tonumber({}))            -- nil

-- Explicit base: integer in that base. Number arg ignored.
print(tonumber("ff", 16))      -- 255
print(tonumber("FF", 16))      -- 255 (case-insensitive)
print(tonumber("10", 2))       -- 2
print(tonumber("10", 8))       -- 8
print(tonumber("10", 36))      -- 36
print(tonumber("z", 36))       -- 35
print(tonumber("-10", 16))     -- -16

-- Digit out of range for the base: nil.
print(tonumber("9", 8))        -- nil  (9 is out of base 8)
print(tonumber("ff", 10))      -- nil
print(tonumber("xyz", 16))     -- nil
-- Base itself out of range [2, 36]: a catchable error (not nil). The
-- parenthesized pcall adjusts to just the boolean status, so the assertion
-- is portable (the error wording/chunk name are not compared).
print((pcall(tonumber, "10", 1)))    -- false  (base < 2)
print((pcall(tonumber, "10", 37)))   -- false  (base > 36)

-- Subtypes: decimal int vs decimal float.
print(math.type(tonumber("5")))       -- integer
print(math.type(tonumber("5.0")))     -- float
print(math.type(tonumber("0x10")))    -- integer
print(math.type(tonumber("1e3")))     -- float

-- Base-N always returns integer.
print(math.type(tonumber("ff", 16)))  -- integer
