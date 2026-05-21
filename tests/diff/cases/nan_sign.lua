-- tostring(0/0) is "-nan" on x86 reference Lua (the IEEE 0.0/0.0 sets the
-- sign bit). WebAssembly canonicalises NaN results to a positive ("nan")
-- pattern, so the sign is not portably reproducible. Captured as a known,
-- platform-dependent delta.
print(tostring(0 / 0))
