-- Real Lua: print(...) joins args with TAB and ends with newline.
-- Currently we only emit args[0]; this test pins the correct behavior.
print(1, 2, 3)
print("a", "b")
print()           -- no args: just a newline
print("solo")
print(nil, true, 42, "x")
