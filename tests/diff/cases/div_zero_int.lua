-- BUG: integer floor-division by zero throws a nil-payload error instead of a
-- catchable message. Reference: false  <chunk>:1: attempt to perform 'n//0'
print(pcall(function() return 3 // 0 end))
