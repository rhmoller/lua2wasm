-- C printf integer rules string.format inherits: the '0' flag is ignored when
-- a precision is given, precision 0 with value 0 prints no digits, '#' forces
-- a leading 0 for octal and 0x only for non-zero hex, and zero padding goes
-- after the sign / 0x prefix. Also "%.f" (precision with no digits) and a
-- trailing lone '%' (an error).
print(string.format("[%05.3d][%05d][%-5d][%+.2d][% d][%+d]", 7, 7, 7, 7, 7, -7))
print(string.format("[%.0d][%.0x][%#.0o][%#o][%#x][%#X][%#08x][%08.3d]", 0, 0, 0, 8, 0, 255, 255, 5))
print(string.format("[%5s][%-5s][%.2s][%5.1s][%c][%3c][%-3c]", "ab", "ab", "abc", "abc", 65, 66, 67))
print(string.format("[%x][%X][%o][%u][%d]", -1, -1, -1, -1, math.mininteger))
print(string.format("[%.f][%.e][%.g][%5.f]", 2.5, 2.5, 2.5, 3.5))
print(string.format("%q", "a\0b\0001\n\"\\\r\1272"))
print(string.format("%q %q %q %q %q", 1, math.mininteger, 1.5, 1/0, -1/0), string.format("%q", 0/0))
-- error cases: status only (message wording is matched semantically, not 1:1)
print((pcall(string.format, "abc%")), (pcall(string.format, "%5%")),
      (pcall(string.format, "%.3c", 65)), (pcall(string.format, "%q", {})),
      (pcall(string.format, "%d", "x")), (pcall(string.format, "%#d", 1)))
print(string.format("%q", "a\0"))
print(string.format("%q", "\1"))
print(string.format("%q", "\0019"))
