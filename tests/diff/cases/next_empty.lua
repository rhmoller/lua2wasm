-- BUG: next on an empty table returns no value instead of nil, so print shows
-- a blank line. Reference: "nil"
print(next({}))
