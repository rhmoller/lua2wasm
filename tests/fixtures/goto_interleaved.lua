-- The actual pattern from goto.lua / closure.lua: multiple labels mixed
-- forward and backward with scopes that interleave. There is no nesting
-- of plain wasm `block` and `loop` that expresses this — needs dispatch.
local a = {}
do
  ::l1:: a[#a + 1] = 1; goto l2;
  ::l2:: a[#a + 1] = 2; goto l5;
  ::l3::
  ::l3a:: a[#a + 1] = 3; goto l1;  -- dead code under this control flow
  ::l4:: a[#a + 1] = 4; goto l6;
  ::l5:: a[#a + 1] = 5; goto l4;
  ::l6::
end
-- Execution order: l1 → 1, l2 → 2, l5 → 5, l4 → 4, l6. l3/l3a unreached.
print(a[1], a[2], a[3], a[4], a[5])
