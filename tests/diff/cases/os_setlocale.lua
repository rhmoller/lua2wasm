-- os.setlocale: querying or setting the portable "C" locale returns "C".
print(os.setlocale())
print(os.setlocale("C"))
print(os.setlocale("C", "all"))
print(os.setlocale(nil, "numeric"))
