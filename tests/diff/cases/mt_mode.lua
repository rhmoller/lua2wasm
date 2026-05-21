-- __mode (weak tables). Impossible under lua2wasm: WasmGC has no weak
-- references, so entries are never reclaimed and a weak table behaves like a
-- strong one. Captured as an architectural gap.
local t = setmetatable({}, {__mode = "v"})
t[1] = {}
collectgarbage()
print(t[1] == nil)
