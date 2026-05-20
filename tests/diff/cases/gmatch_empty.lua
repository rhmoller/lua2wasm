-- gmatch empty-match handling (reference gmatch_aux's `e ~= lastmatch` rule):
-- an empty match whose end coincides with the previous match's end is
-- suppressed, so it does not double separators or trail a spurious "".
local function show(s, p)
  local t = {}
  for w in s:gmatch(p) do t[#t + 1] = "<" .. w .. ">" end
  return table.concat(t)
end
print(show("a,b,,c", "[^,]*"))     -- <a><b><><c>
print(show("abc", "%a*"))          -- <abc>      (no trailing <>)
print(show("", "%a*"))             -- <>
print(show(",,", "[^,]*"))         -- <><><>
print(show("hello world", "%a+"))  -- <hello><world>

-- position-capture + empty-match split idiom (official pm.lua:191)
local sub, res, i = "a  \nbc\t\td", "", 1
for p, e in string.gmatch(sub, "()%s*()") do
  res = res .. string.sub(sub, i, p - 1) .. "-"; i = e
end
print(res)                         -- -a-b-c-d-

-- empty pattern visits every gap exactly once
print(show("xy", ""))              -- <><><>
