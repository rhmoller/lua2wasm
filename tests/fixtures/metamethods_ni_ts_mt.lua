-- __newindex, __tostring, __metatable.

-- --- __tostring ---
local v = setmetatable({x = 42}, {
  __tostring = function(o) return "<v=" .. o.x .. ">" end
})
print(tostring(v))                -- <v=42>
print(v)                          -- <v=42>  (print uses tostring)
print(string.format("%s", v))     -- <v=42>  (format pre-tostrings for %s)
print((pcall(string.format, "%q", v)))  -- false  (a table has no %q literal form)

-- __tostring must return a string; non-string return raises.
local bad = setmetatable({}, { __tostring = function() return 123 end })
print(pcall(tostring, bad))       -- false   nil

-- --- __newindex ---
-- Function form: catches writes whose key isn't already in the table.
local log = {}
local proxy = setmetatable({existing = 1}, {
  __newindex = function(t, k, v) log[#log + 1] = k .. "=" .. tostring(v) end,
})
proxy.foo = 1
proxy.bar = 2
proxy.existing = 99               -- existing key: direct set, no MM
print(proxy.foo, proxy.bar, proxy.existing)   -- nil   nil   99
print(table.concat(log, "; "))                -- foo=1; bar=2

-- rawset bypasses __newindex.
rawset(proxy, "raw", "yes")
print(proxy.raw)                  -- yes

-- Table form: writes redirected to the backing table (chains until a
-- handler is found or a key is "already present").
local backing = {}
local view = setmetatable({}, { __newindex = backing })
view.a = "x"
view.b = "y"
print(backing.a, backing.b)       -- x   y
print(view.a)                     -- nil  (view itself has no __index)

-- --- __metatable ---
-- When set, getmetatable returns its value instead of the actual table.
local protected = setmetatable({}, { __metatable = "locked" })
print(getmetatable(protected))    -- locked

-- setmetatable on a protected value raises (catchable).
print(pcall(setmetatable, protected, {}))                 -- false   nil
print(pcall(setmetatable, protected, nil))                -- false   nil  (still protected)

-- Unprotected metatables behave normally.
local plain = setmetatable({}, { __index = function() return 7 end })
print(type(getmetatable(plain)))  -- table
print(plain.anything)             -- 7
