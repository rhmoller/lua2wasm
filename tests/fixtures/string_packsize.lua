-- string.packsize(fmt) — step 1 of milestone 21.
-- Covers the format parser, alignment math, and the rejections
-- documented in manual §6.5.2.

-- Single fixed-size options (no alignment by default).
print(string.packsize("b"))     -- 1
print(string.packsize("B"))     -- 1
print(string.packsize("h"))     -- 2
print(string.packsize("H"))     -- 2
print(string.packsize("i"))     -- 4
print(string.packsize("I"))     -- 4
print(string.packsize("l"))     -- 8
print(string.packsize("L"))     -- 8
print(string.packsize("j"))     -- 8
print(string.packsize("J"))     -- 8
print(string.packsize("T"))     -- 8
print(string.packsize("f"))     -- 4
print(string.packsize("d"))     -- 8
print(string.packsize("n"))     -- 8

-- i[N] / I[N] with explicit width.
print(string.packsize("i1"))    -- 1
print(string.packsize("i2"))    -- 2
print(string.packsize("i8"))    -- 8
print(string.packsize("I16"))   -- 16

-- c[N] is unaligned bytes.
print(string.packsize("c1"))    -- 1
print(string.packsize("c10"))   -- 10
print(string.packsize("c100"))  -- 100

-- x is one byte of padding (no alignment); X is align-only.
print(string.packsize("x"))     -- 1
print(string.packsize("xxxx"))  -- 4
print(string.packsize("Xi4"))   -- 0 (align-only at offset 0 → no-op)
print(string.packsize("bXi4b")) -- !1 → align-min(4,1)=1 → no pad. 2.

-- Concatenation under default !1 (no alignment).
print(string.packsize("bbbb"))  -- 4
print(string.packsize("bh"))    -- 3
print(string.packsize("bhi4"))  -- 7
print(string.packsize("c2c3"))  -- 5

-- Spaces are ignored.
print(string.packsize("  b   h   "))  -- 3

-- Endianness flags don't affect size.
print(string.packsize("<i4>i4=i4"))   -- 12

-- !N alignment cases.
print(string.packsize("!4 b i4"))     -- b@0, pad 3, i4@4..8 → 8
print(string.packsize("!8 b j"))      -- b@0, pad 7, j@8..16 → 16
print(string.packsize("!2 b h"))      -- b@0, pad 1, h@2..4 → 4
print(string.packsize("!4 b h"))      -- min(2,4)=2 → pad 1 → 4
print(string.packsize("!4 b b h"))    -- b@0, b@1, h@2..4 → 4
print(string.packsize("!16 b j"))     -- min(8,16)=8 → pad 7 → 16
print(string.packsize("!1 b j"))      -- max_align=1 → no pad → 9

-- ! with no [N] means native alignment (8 for us).
print(string.packsize("! b j"))       -- pad 7 → 16

-- Xop aligns without consuming an argument.
print(string.packsize("!4 b Xi4 b"))  -- b@0, Xi4 → pad 3 to 4, b@4 → 5

-- 's' and 'z' must be rejected.
print(pcall(string.packsize, "s"))    -- false  nil
print(pcall(string.packsize, "z"))    -- false  nil
print(pcall(string.packsize, "s4"))   -- false  nil
print(pcall(string.packsize, "bs"))   -- false  nil

-- !N range (1..16).
print(pcall(string.packsize, "!0"))   -- false  nil
print(pcall(string.packsize, "!17"))  -- false  nil

-- i[N]/I[N] range (1..16).
print(pcall(string.packsize, "i17"))  -- false  nil
print(pcall(string.packsize, "I0"))   -- false  nil

-- c without [N] is rejected; c0 is allowed (zero-byte string).
print(pcall(string.packsize, "c"))    -- false  nil
print(string.packsize("c0"))          -- 0
print(string.packsize("bc0b"))        -- 2

-- Non-power-of-2 stride: i3 under !4 forces stride min(3,4)=3 → raise.
print(pcall(string.packsize, "!4 b i3"))  -- false  nil

-- Unknown letter.
print(pcall(string.packsize, "Z"))    -- false  nil
