-- Hex integer literals wrap mod 2^64 per Lua 5.5, even when they
-- exceed LUAI_MAXINTEGER. Decimal integer literals do NOT wrap (those
-- become floats), so we test hex only.

-- A 26-digit literal: full value is 0x13121110090807060504030201;
-- low 64 bits = 0x0807060504030201 = 578437695752307201.
local lnum = 0x13121110090807060504030201
print(lnum)                            -- 578437695752307201

-- 17-digit literal: high nybble drops, low 64 bits remain.
print(0x1ffffffffffffffff)             -- -1   (i64 wrap of 2^65-1)

-- 16-digit (exactly 64 bits): all-ones is -1 in signed.
print(0xffffffffffffffff)              -- -1
print(0x8000000000000000)              -- -9223372036854775808

-- Below the boundary keeps the regular value.
print(0x7fffffffffffffff)              -- 9223372036854775807

-- Wrapping with the high bit set in dropped bytes still works.
print(0xff0807060504030201)            -- 578437695752307201
