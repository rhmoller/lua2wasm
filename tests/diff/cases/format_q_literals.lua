-- %q emits a value readable back as the SAME type: bare number / true / false
-- / nil literals and a quoted string, not "42" / "true".
print(string.format("%q %q %q %q", 42, true, false, nil))
print(string.format("%q", "a\tb"))
