-- Lua has no octal integer syntax — a literal like 08 is just decimal 8.
-- The lexer was passing base 0 to strtoll, which falls into C's octal
-- path on a leading zero and bails on the first digit >= 8.
print(08)              -- 8
print(007)             -- 7
print(010)             -- 10  (NOT 8)
print(08 + 010)        -- 18  (NOT 0+8 = 8)
assert(08 == 8 and 010 == 10)
print("ok")
