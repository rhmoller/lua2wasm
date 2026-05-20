-- BUG: gsub with an empty pattern traps (array OOB) instead of inserting the
-- replacement between every character. Reference: "-a-b-c-"  4
print(string.gsub("abc", "", "-"))
