-- Hex integer and hex-float literals (Lua 5.5 §3.1).

-- Hex integers.
print(0xff)                   -- 255
print(0xFF)                   -- 255
print(0Xff)                   -- 255 (capital X also accepted)
print(0xCAFE)                 -- 51966
print(0x10)                   -- 16
print(0x0)                    -- 0

-- Subtype: hex without a fraction or exponent is integer.
print(math.type(0xff))        -- integer
print(math.type(0x0))         -- integer

-- Hex floats: need a '.fraction' or a 'p<exponent>' (or both).
print(0x1p3)                  -- 8.0        (1 * 2^3)
print(0x1.8p0)                -- 1.5        (1 + 8/16)
print(0x1.8p1)                -- 3.0
print(0x1p-1)                 -- 0.5
print(0xA.B)                  -- 10.6875    (10 + 11/16)
print(0x0.4p4)                -- 4.0

-- Subtype: presence of '.' or 'p' forces float.
print(math.type(0x1p3))       -- float
print(math.type(0x1.0))       -- float
print(math.type(0xff))        -- integer  (unchanged)

-- Hex literals are valid arithmetic operands.
print(0xff + 1)               -- 256
print(0x10 * 2)               -- 32
print(0xff // 16)             -- 15
print(0xff % 16)              -- 15

-- Unary minus operates on the literal value, not the bytes.
print(-0xff)                  -- -255

-- Hex digits a-f and A-F are both valid.
print(0xabcdef)               -- 11259375
print(0xABCDEF)               -- 11259375
