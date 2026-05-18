-- Milestone 25 entry point. Exercises require() against two modules.

-- Direct require returning a table.
local util = require("util")
print(util.shout("ok"))                -- OK!
print(util.dup("ab"))                  -- abab

-- Caching: second require returns the same object.
local util2 = require("util")
print(util == util2)                   -- true

-- Module that itself requires another module.
local wrap = require("wrap")
print(wrap.banner("hello"))            -- === HELLO ===!
print(wrap.echo2("xy"))                -- xyxy

-- Missing module raises (catchable).
print(pcall(require, "nope"))          -- false  nil

-- _G has package available.
print(type(package))                    -- table
print(type(package.loaded))             -- table
print(type(package.preload))            -- table
print(package.loaded.util == util)      -- true
