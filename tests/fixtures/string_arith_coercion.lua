-- Lua's arithmetic operators coerce strings that look like numbers.
-- The official tests assume this (math.lua line 92: `assert(a+b == 5
-- and -b == -3 and b+"2" == 5 and "10"-c == 0)`).
print("2" + " 3e0 ")        -- 5.0
print("10" - "  3")          -- 7
print("2" * 3)                -- 6
print(3 / "2")                -- 1.5
print("10" % "3")             -- 1
print(-("3"))                 -- -3
print("2" ^ "10")             -- 1024.0
print("12" // 5)              -- 2

-- Both operands strings: arithmetic still works.
print(("4") + ("5"))          -- 9
