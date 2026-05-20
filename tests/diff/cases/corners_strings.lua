-- String corners that already match reference Lua 5.5.
print("a\0b" < "a\0c", "ab" < "abc", "Z" < "a")
print(#"a\0b\0c", string.len("a\0b"))
print(("hello"):sub(-3), ("hello"):sub(2, -2), ("hello"):sub(-100, 100), ("hi"):sub(5))
print("(" .. ("ab"):rep(0) .. ")", ("x"):rep(3, ","))
print(string.char(72, 105), ("AB"):byte(1, 2))
print(string.format("[%5d][%-5d][%05.2f][%+d][% d][%.3s]", 42, 42, 3.14159, 7, 7, "abcdef"))
print(string.format("%x %X %o %c", 255, 255, 8, 65))
print(tonumber("  10  "), tonumber("0x1A"), tonumber(".5"), tonumber("1e3"),
      tonumber("inf"), tonumber("0x"), tonumber(""), tonumber("nan"))
print(tonumber("ff", 16), tonumber("z", 36), tonumber("10", 2), tonumber("8", 8))
