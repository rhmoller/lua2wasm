-- BUG: table.concat ignores the i/j range arguments. Reference: "20,30"
print(table.concat({10, 20, 30}, ",", 2, 3))
print(table.concat({"a", "b", "c", "d"}, "-", 2))
