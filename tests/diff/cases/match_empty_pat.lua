-- An empty pattern in string.match was an OOB crash (eager i32.and read pat[0]).
-- Empty matches must also work: match returns the empty string.
print(string.match("abc", ""))
print(string.match("hello", "l*"))
print(string.find("abc", ""))
