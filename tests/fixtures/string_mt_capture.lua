-- A string's methods come from its metatable (captured at library load),
-- not a live _G.string lookup, so reassigning the `string` global after the
-- first string operation must not break string methods.
local s = "Hello"
print(s:upper())
string = nil
print(s:lower())
print(("ab"):rep(3))
print(#"abc", ("xyz"):sub(2))
