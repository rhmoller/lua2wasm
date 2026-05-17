-- Permissive default: undeclared names are globals, the way stock Lua
-- has worked forever. (Strict mode is a future opt-in.)

num = 42
print(num)              -- 42

greeting = "hi"
function greet(who)
  return greeting .. ", " .. who
end
print(greet("world"))   -- "hi, world"

-- Reading an undeclared name yields nil (Lua tradition).
print(undeclared_var)   -- nil

-- Same global re-assigned later.
num = num + 1
print(num)              -- 43

-- Function defined at top level becomes a global too.
function double(x) return x * 2 end
print(double(21))       -- 42
