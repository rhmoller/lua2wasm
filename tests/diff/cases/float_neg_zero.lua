-- BUG: negative zero loses its sign. Reference: "-0.0"
print(tostring(-0.0))
print(-0.0)
