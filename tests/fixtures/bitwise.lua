-- Bitwise operators (Lua 5.5 §3.4.2).
--
-- All bit ops operate on signed 64-bit integers. Floats with no
-- fractional part and in i64 range are accepted (and converted);
-- everything else (non-integer floats, NaN, infinities, non-numbers)
-- falls through to the metamethod path or raises.

-- AND.
print(0xF0 & 0x0F)              -- 0
print(0xF0 & 0xFF)              -- 240
print(0xFFFF & 0xFF00)          -- 65280
print(0 & 0xFFFFFFFF)           -- 0

-- OR.
print(0xF0 | 0x0F)               -- 255
print(0xAA | 0x55)               -- 255
print(0 | 0)                     -- 0

-- XOR (binary `~`).
print(0xF0 ~ 0xFF)               -- 15
print(0xFF ~ 0xFF)               -- 0
print(0xAA ~ 0xFF)               -- 85

-- Unary NOT.
print(~0)                        -- -1   (all bits set)
print(~-1)                       -- 0
print(~0xFF)                     -- -256

-- Left shift.
print(1 << 0)                    -- 1
print(1 << 1)                    -- 2
print(1 << 4)                    -- 16
print(1 << 8)                    -- 256
print(7 << 5)                    -- 224

-- Right shift (LOGICAL — fills with zeros).
print(256 >> 2)                  -- 64
print(0xFF >> 4)                 -- 15
print(0xFFFFFFFF >> 28)          -- 15

-- Negative shift counts swap direction.
print(1 << -1)                   -- 0     (= 1 >> 1)
print(8 << -2)                   -- 2     (= 8 >> 2)
print(8 >> -2)                   -- 32    (= 8 << 2)

-- |count| >= 64 yields 0.
print(1 << 64)                   -- 0
print(1 << 65)                   -- 0
print(1 << -64)                  -- 0
print(0xFF >> 64)                -- 0

-- Precedence: << >> > & > ~ (binary xor) > |.
print(1 | 2 & 3)                 -- 1 | (2 & 3) = 3
print(1 << 2 | 1)                -- (1 << 2) | 1 = 5
print(1 + 2 << 1)                -- (1+2) << 1 = 6
print(0xFF & 0x0F | 0xF0)        -- (0xFF & 0x0F) | 0xF0 = 0x0F | 0xF0 = 255

-- Float with integer value is convertible.
print(2.0 & 3.0)                 -- 2
print(2.0 << 1)                  -- 4
print(~3.0)                      -- -4

-- Non-integer float / NaN / non-numeric (no metamethod) raises.
print(pcall(function() return 1.5 & 2 end))                    -- false   nil
print(pcall(function() return (0/0) & 2 end))                  -- false   nil
print(pcall(function() return "x" & 2 end))                    -- false   nil
print(pcall(function() return ~1.5 end))                       -- false   nil

-- Metamethods on a non-numeric operand fire (left-then-right).
local v = setmetatable({}, {
  __band = function() return "band" end,
  __bor  = function() return "bor"  end,
  __bxor = function() return "bxor" end,
  __shl  = function() return "shl"  end,
  __shr  = function() return "shr"  end,
  __bnot = function() return "bnot" end,
})
print(v & 1,  1 & v)             -- band   band
print(v | 1,  1 | v)             -- bor    bor
print(v ~ 1,  1 ~ v)             -- bxor   bxor
print(v << 1, 1 << v)            -- shl    shl
print(v >> 1, 1 >> v)            -- shr    shr
print(~v)                        -- bnot

-- Subtype: bitops always return integers.
print(math.type(0xFF & 0x0F))    -- integer
print(math.type(1 << 4))         -- integer
print(math.type(~0))             -- integer
print(math.type(2.0 & 3.0))      -- integer
