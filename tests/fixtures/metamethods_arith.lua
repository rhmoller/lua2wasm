-- All arithmetic metamethods: __add __sub __mul __div __mod __pow
-- __unm __idiv. Each is consulted only when one or both operands
-- are not numeric.

local v = setmetatable({}, {
  __add  = function(a,b) return "add"  end,
  __sub  = function(a,b) return "sub"  end,
  __mul  = function(a,b) return "mul"  end,
  __div  = function(a,b) return "div"  end,
  __mod  = function(a,b) return "mod"  end,
  __pow  = function(a,b) return "pow"  end,
  __unm  = function(a)   return "unm"  end,
  __idiv = function(a,b) return "idiv" end,
})

-- Each binary op consults the metamethod when either operand isn't numeric.
print(v + 1, 1 + v)         -- add   add
print(v - 1, 1 - v)         -- sub   sub
print(v * 1, 1 * v)         -- mul   mul
print(v / 1, 1 / v)         -- div   div
print(v % 1, 1 % v)         -- mod   mod
print(v ^ 2, 2 ^ v)         -- pow   pow
print(v // 2, 2 // v)       -- idiv  idiv

-- __unm is unary.
print(-v)                    -- unm

-- Both operands carrying the metamethod: the LEFT operand's handler wins.
local w = setmetatable({}, { __add = function() return "w" end })
print(v + w)                 -- add  (v's left-side handler)

-- Pure-number path is unchanged.
print(2 + 3)                 -- 5
print(7 // 3)                -- 2
print(-7 % 3)                -- 2 (floor mod)
print(2 ^ 0.5 > 1.4)         -- true

-- Missing metamethod with non-numeric operand → catchable error.
local bare = setmetatable({}, {})
print(pcall(function() return bare + 1 end))   -- false   nil
print(pcall(function() return -bare end))      -- false   nil
