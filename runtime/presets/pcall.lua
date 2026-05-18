local function safediv(a, b)
  if b == 0 then error("division by zero") end
  return a / b
end
print(pcall(safediv, 10, 2))   -- true 5.0
print(pcall(safediv, 1, 0))    -- false "division by zero"
