--[[
  Examples from TJ Devries: "Everything You Need To Start Writing Lua"
  https://www.youtube.com/watch?v=CuWfgiwI73Q
--]]

-- This is a comment, It starts with two dashes

--[[ This is also
     a comment.

     But it spans multiple lines!
--]]

local number = 5

local string = "hello, world"
local single = "also works"
local crazy = [[ This
 is multie line and literal ]]

local truth, lies = true, false

local nothing = nil

local function hello(name)
	print("Hello!", name)
end

local greet = function(name)
	-- .. is string concatenation
	print("Greetings, " .. name .. "!")
end

local higher_order = function(value)
	return function(another)
		return value + another
	end
end

local add_one = higher_order(1)
print("add_one(2) -> ", add_one(2))

local list = {
	"first",
	2,
	false,
	function()
		print("Fourth!")
	end,
}
print("Yup, 1-indexed", list[1])
print("Fourth is 4 ... :", list[4]())

local t = {
	literal_key = "a string",
	["an expression"] = "also works",
	[function() end] = true,
}

print("literal_key   : ", t.literal_key)
print("an expression : ", t["an expression"])
print("function() end: ", t[function() end]) -- this print nil, but should print nothing

local favorite_accounts = { "teej_dv", "ThePrimeagen", "terminaldotshop" }
for index = 1, #favorite_accounts do
	print(index, favorite_accounts[index])
end

for index, value in ipairs(favorite_accounts) do
	print(index, value)
end

local reading_scores = { teej_dv = 9.5, ThePrimeagen = "N/A" }
for index = 1, #reading_scores do
	print(reading_scores[index])
end

for key, value in pairs(reading_scores) do
	print(key, value)
end

local function action(loves_coffee)
	if loves_coffee then
		print("Check out `ssh terminal.shop` - it's cool!")
	else
		print("Check out `ssh terminal.shop` - it's still cool!")
	end
end

-- "falsey": nil, false
action()
action(false)

-- Everything else is "truthy"
action(true)
action(0)
action({})

--[[ these are wonky since we don't support multiple files in this playground

-- foo.lua
local M = {}
M.cool_function = function() end
return M

-- bar.lua
local foo = require('foo')
foo.cool_function()

--]]

local returns_four_values = function()
	return 1, 2, 3, 4
end

first, second, last = returns_four_values()

print("first: ", first)
print("second:", second)
print("last:", last)
-- the `4` is discarded :'(

local variable_arguments = function(...)
	local arguments = { ... }
	for i, v in ipairs({ ... }) do
		print(i, v)
	end
	return table.unpack(arguments)
end

print("===================")
print("1:", variable_arguments("hello", "world", "!"))
print("===================")
print("2:", variable_arguments("hello", "world", "!"), "<lost>")

local single_string = function(s)
	return s .. " - WOW!"
end

local x = single_string("hi")
local y = single_string("hi")
print(x, y)

local setup = function(opts)
	if opts.default == nil then
		opts.default = 17
	end

	print(opts.default, opts.other)
end

setup({ default = 12, other = false })
setup({ other = true })

local MyTable = {}

function MyTable.something(self, ...) end
function MyTable:something(...) end

local vector_mt = {}
vector_mt.__add = function(left, right)
  return setmetatable({
    left[1] + right[1],
    left[2] + right[2],
    left[3] + right[3],
  }, vector_mt)
end

local v1 = setmetatable({ 3, 1, 5 }, vector_mt)
local v2 = setmetatable({ -3, 2, 2 }, vector_mt)
local v3 = v1 + v2
print(v3[1], v3[2], v3[3])
print(v3 + v3)



local fib_mt = {
  __index = function(self, key)
    if key < 2 then return 1 end
    -- Update the table, to save the intermediate results
    self[key] = self[key - 2] + self[key - 1]
    -- Return the result
    return self[key]
  end
}

local fib = setmetatable({}, fib_mt)

print(fib[5])
print(fib[1000])
