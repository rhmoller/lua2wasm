-- the sieve of Eratosthenes programmed with coroutines (from lua.org/extras)
--
-- NOTE: lua2wasm does NOT support coroutines yet — phase 9, blocked on the
-- WASM stack-switching proposal shipping in browsers. This file is kept in
-- the repo for reference but is *not* part of the test suite.

function gen (n)
  return coroutine.wrap(function ()
    for i=2,n do coroutine.yield(i) end
  end)
end

function filter (p, g)
  return coroutine.wrap(function ()
    for n in g do
      if n%p ~= 0 then coroutine.yield(n) end
    end
  end)
end

N=N or 500
x = gen(N)
while 1 do
  local n = x()
  if n == nil then break end
  print(n)
  x = filter(n, x)
end
