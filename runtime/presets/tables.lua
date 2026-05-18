local t = {10, 20, 30, name = "alice"}
print(t[1])
print(t.name)
print(#t)

local nested = {inner = {x = 1, y = 2}}
print(nested.inner.x + nested.inner.y)
