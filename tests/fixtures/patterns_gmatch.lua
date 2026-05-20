-- string.gmatch — step 6. Iterator over successive matches.
-- Returns the captures (or whole match) of each match, in order.

-- Whole-match iteration with no captures.
local words = {}
for w in string.gmatch("alpha beta gamma", "%a+") do words[#words+1] = w end
print(table.concat(words, ","))                            -- alpha,beta,gamma

-- With captures: yields multiple values per step.
for k, v in string.gmatch("a=1 b=2 c=3", "(%a)=(%d)") do
  print(k, v)
end
-- expect three lines: a 1 / b 2 / c 3

-- Empty-match handling: '%a*' on "abc" yields just "abc". The trailing
-- empty match is suppressed because its end equals the previous match's end
-- (reference gmatch's `e ~= lastmatch` rule), so n == 1, not 2.
local n = 0
for _ in string.gmatch("abc", "%a*") do n = n + 1 end
print(n)                                                    -- 1

-- init argument starts the iteration at byte position init.
for w in string.gmatch("foo bar baz", "%a+", 5) do
  print(w)
end
-- expect: bar / baz

-- Mid-pattern position capture is yielded too.
for pos, num in string.gmatch("a:42 b:7 c:101", "%a:()(%d+)") do
  print(pos, num)
end
-- expect: 3 42 / 8 7 / 12 101

-- No matches.
local count = 0
for _ in string.gmatch("hello", "x+") do count = count + 1 end
print(count)                                                -- 0
