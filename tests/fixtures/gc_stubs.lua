-- collectgarbage, debug.gethook, and load are stubs: lua2wasm runs on
-- the host GC and has no runtime compiler, but the official 5.5 tests
-- assume these names exist. The stubs return values that match the
-- shape Lua promises, so calls don't blow up the program.
print(collectgarbage())                    -- 0
print(collectgarbage("count"))             -- 0.0
print(collectgarbage("isrunning"))         -- true
print(collectgarbage("stop"))              -- 0
print(collectgarbage("step", 1))           -- 0

local h, m, c = debug.gethook()
print(h, m, c)                             -- nil  (empty)  0

local f, err = load("return 1")
print(f, type(err))                        -- nil  string
