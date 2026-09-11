-- Like deep_recursion, but each frame carries many locals and arithmetic
-- temporaries (a big wasm frame). The overflow guard is a frame-weight
-- budget, so this must still raise a *catchable* "stack overflow" instead of
-- tripping the engine's uncatchable stack limit first.
local function g(n)
  local a, b, c, d = n * 2, n - 1, n / 3, n + 5
  local e, h = a * b, c + d
  if n == 0 then return 0 end
  return 1 + g(n - 1) + a - a + b - b + e - e + h - h
end
local ok, err = pcall(g, 1000000)
print(ok, type(err) == "string" and err:find("stack overflow", 1, true) ~= nil)
print(pcall(g, 50))
