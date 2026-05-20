-- BUG: %q must emit a backslash followed by a real newline so the result reads
-- back as the same string; lua2wasm emits the literal "\n" escape instead.
print(string.format("%q", "tab\tline\n"))
