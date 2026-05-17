-- A simple example of OOP in Lua (from PiL 1, ch. 16).
-- Adapted for lua2wasm: only the `global` declarations have been added; the
-- rest is byte-for-byte the original from lua.org/extras.

global Account = {balance = 0}

function Account:new (o, name)
  o = o or {name=name}
  setmetatable(o, self)
  self.__index = self
  return o
end

function Account:deposit (v)
  self.balance = self.balance + v
end

function Account:withdraw (v)
  if v > self.balance then error("insufficient funds on account "..self.name) end
  self.balance = self.balance - v
end

function Account:show (title)
  print(title or "", self.name, self.balance)
end

global a = Account:new(nil,"demo")
a:show("after creation")
a:deposit(1000.00)
a:show("after deposit")
a:withdraw(100.00)
a:show("after withdraw")
