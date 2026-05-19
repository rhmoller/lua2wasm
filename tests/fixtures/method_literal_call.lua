-- Method-call shorthand: `obj:method"str"` and `obj:method{k=v}`.
local obj = {}
function obj:greet(name) print("hello " .. name) end
function obj:dump(t) print(t.k) end
obj:greet "world"
obj:dump { k = "value" }
