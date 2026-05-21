-- __gc finalizers. Impossible under lua2wasm's hard constraint of no bundled
-- GC: the host collector owns every value's lifetime and WasmGC exposes no
-- finalization hook, so __close-style cleanup at collection time can never
-- fire. collectgarbage() is a stub. Captured as an architectural gap.
setmetatable({}, {__gc = function() print("collected") end})
collectgarbage()
print("after")
