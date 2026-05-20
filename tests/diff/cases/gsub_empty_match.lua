-- BUG: empty matches of " *" are applied twice per position, doubling the
-- separators. Reference: "-a-b-c-d-"  5
print(string.gsub("a b cd", " *", "-"))
