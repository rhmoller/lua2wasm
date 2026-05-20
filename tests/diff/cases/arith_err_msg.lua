-- BUG: arithmetic error messages drop the "on a <type> value" suffix, and the
-- chunk name strips the ".lua" extension. Reference:
--   false  arith_err_msg.lua:1: attempt to perform arithmetic on a nil value
print(pcall(function() return nil + 1 end))
