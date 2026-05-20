-- BUG: tonumber does not parse hexadecimal floats (the lexer does, but the
-- runtime string->number path does not). Reference: 16.0  0.5
print(tonumber("0x1p4"))
print(tonumber("0x.8"))
