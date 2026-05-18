-- patterns soak fixture (step 9 closing milestone 20).
-- Exercises every documented pattern feature, plus the plain flag.

-- All character classes.
print(string.match("Hello123world", "%a+"))            -- Hello
print(string.match("abc123def", "%d+"))                -- 123
print(#string.match("foo\t bar", "%s+"))               -- 2  (\t + space)
print(string.match("FooBar", "%u+"))                   -- F
print(string.match("FooBar", "%l+"))                   -- oo
print(string.match("a1b2c3", "%w+"))                   -- a1b2c3
print(string.match("0xCAFE", "%x+"))                   -- 0
print(string.match("foo, bar.", "%p+"))                -- ,
print(#string.match("\1\2x", "%c+"))                   -- 2  (two control bytes)
print(string.match("hello!@#", "%g+"))                 -- hello!@#

-- Negated classes.
print(string.find("abc123", "%D+"))                    -- 1   3   (non-digits)
print(string.find("hi there", "%S+"))                  -- 1   2   (non-space)

-- Sets and ranges.
print(string.match("hello", "[aeiou]+"))               -- e
print(string.match("a-1b-2", "[0-9-]+"))               -- 1
print(string.match("abc1def2", "[%a]+"))               -- abc
print(string.match("**!!%%", "[^%a%d]+"))              -- **!!%%

-- Quantifiers.
print(string.match("aaa", "a*"))                       -- aaa
print(string.match("ab", "a*b"))                       -- ab
print(string.match("b",  "a*b"))                       -- b
print(string.match("aaaa", "a-a"))                     -- a   (lazy)
print(string.match("color", "colou?r"))                -- color
print(string.match("colour", "colou?r"))               -- colour

-- Anchors.
print(string.match("hello", "^he"))                    -- he
print(string.match("hello", "lo$"))                    -- lo
print(string.match("hello", "^hello$"))                -- hello
print(string.find("xhello", "^he"))                    -- nil

-- Captures and back-refs.
print(string.match("hello world", "(%a+)%s+(%a+)"))    -- hello   world
print(string.match("abcabc", "(.-)%1"))                -- abc
print(string.match("xyzxyz", "(%a)(%a)%2%1"))          -- nil   (no palindrome match for yzxyz...)
print(string.match("noon", "(%a)(%a)%2%1"))            -- n   o

-- Position captures.
print(string.match("foo123bar", "(%a+)()"))            -- foo   4

-- %bxy and %f[set].
print(string.match("a(b(c)d)e", "%b()"))               -- (b(c)d)
print(string.find("hello world", "%f[%a]world"))       -- 7   11

-- gmatch fundamentals.
do
  local t = {}
  for k, v in string.gmatch("a=1, b=2, c=3", "(%a)=(%d)") do
    t[#t+1] = k .. v
  end
  print(table.concat(t, ","))                          -- a1,b2,c3
end

-- gsub variants.
print(string.gsub("hello", "l", "L"))                  -- heLLo   2
print(string.gsub("(foo)(bar)", "%((%a+)%)", "<%1>"))  -- <foo><bar>  2
print(string.gsub("AAA", "A", string.lower))           -- aaa     3
print(string.gsub("abc", "(.)(.)", "%2%1"))            -- bac     1

-- gsub with table dispatch.
do
  local replacements = {hello="hi", world="earth"}
  print(string.gsub("hello world", "%a+", replacements))
  -- hi earth   2
end

-- Plain mode: literal byte search.
print(string.find("foo.bar", ".", 1, true))            -- 4   4
print(string.find("a*b*c", "*", 1, true))              -- 2   2
print(string.find("abc", "%d", 1, true))               -- nil
