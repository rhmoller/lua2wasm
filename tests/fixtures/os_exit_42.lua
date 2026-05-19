-- Verifies os.exit propagates the code to the host.
print("before")
os.exit(42)
print("never")
