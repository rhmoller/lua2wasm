-- Reference Lua rejects a goto that jumps into the scope of a local at compile
-- time ("jumps into the scope of 'x'"), reported where the label is. The
-- harness compares the rejection by line and message;
-- tests/test_compile_checks.sh covers the rest of the rules.
do
  goto skip
  local x = 1
  ::skip::
  print("ran")
end
