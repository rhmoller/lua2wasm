-- Fixture for the --embed-api host-call ABI. There is no print output to diff;
-- tests/test_embed_api.mjs compiles this with --embed-api, runs main() to
-- define these globals, then calls them from the host via lua_get_global /
-- lua_args_* / lua_call and checks the results.

function add(a, b)
    return a + b
end

function greet(name)
    return "hello, " .. name
end

-- multiple return values
function divmod(a, b)
    return a // b, a % b
end

-- persistent state across host calls (one instance, called repeatedly)
counter = 0
function tick()
    counter = counter + 1
    return counter
end

-- raising a Lua error should surface to the host as the LuaError tag
function boom()
    error("kaboom")
end
