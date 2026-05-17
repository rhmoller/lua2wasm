-- string.format subset: %s %d %g %f %e %x %% with optional precision
print(string.format("hi"))                        -- "hi"
print(string.format("%d", 42))                    -- "42"
print(string.format("%d", -7))                    -- "-7"
print(string.format("%s/%s", "a", "b"))           -- "a/b"
print(string.format("[%d, %d, %d]", 1, 2, 3))     -- "[1, 2, 3]"
print(string.format("%g", 1.5))                   -- "1.5"
print(string.format("%.17g", 3.141592653589793))  -- a 17-significant-digit pi
print(string.format("%.2f", 3.14159))             -- "3.14"
print(string.format("%.1e", 12345))               -- "1.2e+4"
print(string.format("%x", 255))                   -- "ff"
print(string.format("100%%"))                     -- "100%"
print(string.format("n=%d  s=%s  pi=%g", 7, "hi", 3.14)) -- "n=7  s=hi  pi=3.14"
