-- Regression anchor: string library calls that already match reference.
print(("Hello"):upper(), ("WORLD"):lower(), ("hi"):rep(3, "-"))
print(("abcdef"):sub(2, 4), #"héllo", ("racecar"):reverse())
print(string.format("%d %5.2f %x", 42, 3.14159, 255))
print(string.match("key = value", "(%w+)%s*=%s*(%w+)"))
local up = string.gsub("hello world", "%w+", function(w) return w:upper() end)
print(up)
