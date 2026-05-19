-- The official test suite opens every file with `require "string"` etc.
-- to make sure the stdlib modules are accessible through both _G and the
-- module system. stdlib_init must therefore register each built library
-- in package.loaded so require() returns it.
assert(require "string" == string)
assert(require "math"   == math)
assert(require "table"  == table)
assert(require "io"     == io)
assert(require "utf8"   == utf8)
assert(require "debug"  == debug)
assert(require "package" == package)
print("ok")
