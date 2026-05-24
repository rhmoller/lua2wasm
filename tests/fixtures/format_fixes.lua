-- %x/%X/%o/%u of negatives are unsigned (two's complement);
-- %f/%e round ties-to-even (C printf), not ties-away.
print(string.format("%x %X %o", -1, -1, -1))
print(string.format("%x %u", -255, -255))
print(string.format("%x", 0x7fffffffffffffff))
print(string.format("%#x %#o", 255, 8))
-- ties-to-even at the rounding digit
print(string.format("%.0f %.0f %.0f %.0f %.0f", 0.5, 1.5, 2.5, 3.5, 4.5))
print(string.format("%.1f %.1f %.1f", 0.25, 0.35, 0.45))
print(string.format("%.2f", 2.675))
print(string.format("%.0e %.0e %.0e", 2.5, 3.5, 1.5))
print(string.format("%.2e", 9.995))
print(string.format("%.3e", 12345.6))
-- negative and sign flags still work
print(string.format("%.1f % .1f %+.1f", -2.5, 2.5, 2.5))
-- %s precision/width count bytes (utf8 source)
print(string.format("[%.3s][%6s]", "héllo", "ab"))
