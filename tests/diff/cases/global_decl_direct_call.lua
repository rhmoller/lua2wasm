-- A direct call to a local function whose only call site is the value of a
-- `global` declaration (the site-inference pass skipped those values, so the
-- callee's direct entry was never emitted: "unknown function $user_N_da").
global print, string
local function inc(n) return n + 1 end
local function pair(a, b) return a * 10 + b end
global x = inc(1)
global y, z = pair(2, 3), inc(x)
print(x, y, z)
local function fmt(v) return string.format("%.1f", v) end
global w = fmt(2.25)
print(w)
