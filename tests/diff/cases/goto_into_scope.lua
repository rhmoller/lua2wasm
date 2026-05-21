-- Reference Lua rejects a goto that jumps into the scope of a local at compile
-- time ("jumps into the scope of 'x'"). lua2wasm accepts and runs it. A
-- correct check needs per-block active-variable tracking in the parser. This
-- is compile-error parity: the harness can only see <compile-fail> vs
-- reference's diagnostic, so it stays captured here rather than turning green.
do
  goto skip
  local x = 1
  ::skip::
  print("ran")
end
