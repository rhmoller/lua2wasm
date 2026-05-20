-- BUG: parenthesizing a multi-value call or vararg must adjust it to exactly
-- one value. (f()) keeps all results here. Reference: "7" then "bb".
print((table.unpack({ 7, 8, 9 })))
print((string.gsub("aa", "a", "b")))
