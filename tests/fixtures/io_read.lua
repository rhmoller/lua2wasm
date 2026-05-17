-- Exercises io.read(); the test pipes two lines of stdin.
local first = io.read()
local second = io.read()
local third = io.read()        -- EOF -> nil
print(first)
print(second)
print(third)
