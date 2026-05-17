-- A "stateful closure as iterator" — the simplest form of a generic-for
-- iterator. numberGenerator returns a closure that captures `start` in a
-- mutable upvalue; each call advances it and returns either the next number
-- or nothing (which generic-for interprets as the end).
local function numberGenerator(start, stop)
    return function()
        start = start + 1
        if start <= stop then
            return start
        end
    end
end

-- prints 2, 3, 4, 5
for num in numberGenerator(1, 5) do
    print(num)
end

-- A second instance has its own captured `start` — closures don't share.
local g = numberGenerator(10, 12)
print(g())   -- 11
print(g())   -- 12
print(g())   -- nil (terminates the iteration)
