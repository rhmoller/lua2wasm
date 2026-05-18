-- goto / ::label:: — common patterns.

-- 1. Forward-only: skip a section.
do
  print("a")
  goto skip
  print("not reached")
  ::skip::
  print("c")
end

-- 2. continue pattern in a numeric for-loop.
for i = 1, 5 do
  if i == 3 then goto cont end
  print("for", i)
  ::cont::
end

-- 3. Backward-only: simple retry / counter loop.
do
  local i = 0
  ::loop::
  i = i + 1
  if i < 3 then goto loop end
  print("counted", i)
end

-- 4. Multiple forward labels nest as outer-= later.
do
  goto A
  ::A::
  goto B
  ::B::
  print("nested fwd")
end

-- 5. Same label with both forward (entry) and backward (retry).
do
  local n = 0
  if n == 0 then goto retry end
  print("not reached either")
  ::retry::
  n = n + 1
  if n < 3 then goto retry end
  print("retry done, n =", n)
end

-- 6. goto out of nested do.
do
  do
    do
      goto out
      print("not reached")
    end
  end
  ::out::
  print("escaped nested do")
end

-- 7. goto inside generic for, continuing.
local sum = 0
for _, v in ipairs({1, 2, 3, 4, 5}) do
  if v % 2 == 0 then goto next end
  sum = sum + v
  ::next::
end
print("odd sum", sum)              -- 1+3+5 = 9

-- 8. Errors caught at compile time would prevent compile; pcall doesn't
--    apply. The next two patterns are runtime-safe.

-- 9. goto reentering the start of a do-block (forward at function scope).
do
  ::start::
  local x = 1
  if x == 1 then goto done end
  print("never")
  ::done::
end
print("after start/done block")
