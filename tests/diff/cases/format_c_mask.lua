-- string.format("%c", n) outputs the low byte of n (n & 0xff) as a 1-byte
-- string, computed in 64-bit. The old Number(iv)&0xff lost precision for large
-- magnitudes and masked at 32 bits. Fuzzer-found. (string.byte for a portable
-- numeric golden.)
local function c(n) return string.byte(string.format("%c", n)) end
print(c(65))                       -- 65
print(c(0xFE))                     -- 254
print(c(256))                      -- 0
print(c(257))                      -- 1
print(c(-1))                       -- 255
print(c(math.maxinteger))          -- 255
print(c(math.mininteger))          -- 0
print(c(9223372036854775806))      -- 254
print(c(~math.maxinteger))         -- 0  (mininteger)
