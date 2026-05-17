-- Exercises the five new bits from the lua.org tutorial pass:
--   math.sin/cos/tan/asin/acos/atan/exp/log/pi
--   paren-less call sugar  (print "x"   and   h{k=1})
--   long-bracket strings   ([[ ... ]])
--   table identity equality via ref.eq
-- io.read is exercised by a separate test that pipes stdin.

-- math constants and transcendentals
print(math.pi > 3.14 and math.pi < 3.15)   -- true
print(math.sin(0))                          -- 0.0
print(math.cos(0))                          -- 1.0
-- Round to 6 dp via string.format so floating-point noise doesn't break the diff.
print(string.format("%.6f", math.sin(math.pi / 2)))  -- 1.000000
print(string.format("%.6f", math.exp(0)))            -- 1.000000
print(string.format("%.6f", math.log(math.exp(1)))) -- 1.000000

-- paren-less single-string-arg call
print "hello"
-- paren-less single-table-arg call
local function h(x) return x.k end
print(h{k = "value"})

-- long-bracket string
local u = [[ Double brackets
       start and end
       multi-line strings.]]
print(#u > 30)        -- true
print(string.sub(u, 1, 16))   -- " Double brackets"

-- table identity
local t = {}
local same = t
local fresh = {}
print(t == same)      -- true (same reference)
print(t == fresh)     -- false (different reference)
local store = {[t] = "stored"}
print(store[t])       -- "stored"
print(store[fresh])   -- nil
