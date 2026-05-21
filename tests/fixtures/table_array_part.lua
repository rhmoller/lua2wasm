-- array part stress: sequential, sparse, holes, mixed, table.*, iteration
local a = {}; for i=1,10 do a[i]=i*i end
print(#a, a[1], a[10])                              -- 10 1 100
a[11]=121; print(#a)                               -- 11 (append)
a[20]=400; print(#a, a[20])                         -- 11 400 (sparse->hash)
a[12]=144; a[13]=169; print(#a)                     -- 13 (append, sparse 20 stays)
-- hole via middle delete -> demote, still correct
local b={1,2,3,4,5}; b[3]=nil; print(b[1],b[2],b[3],b[4],b[5])  -- 1 2 nil 4 5
-- table.insert/remove
local c={}; for i=1,6 do table.insert(c,i) end
table.insert(c,3,99); print(table.concat(c,","))   -- 1,2,99,3,4,5,6
table.remove(c,1); print(table.concat(c,","))      -- 2,99,3,4,5,6
print(#c)                                           -- 6
-- ipairs stops at first nil; pairs covers all
local d={10,20,nil,40}; local s=0; for _,v in ipairs(d) do s=s+v end; print(s)  -- 30
-- pairs over array+hash
local m={}; for i=1,4 do m[i]=i end; m.name="x"; m.flag=true
local ints,strs=0,0
for k,v in pairs(m) do if type(k)=="number" then ints=ints+1 else strs=strs+1 end end
print(ints,strs)                                    -- 4 2
-- next() explicit
local t={7,8}; local k1,v1=next(t); print(k1,v1)   -- 1 7
local k2,v2=next(t,k1); print(k2,v2)               -- 2 8
print(next(t,k2))                                   -- nil
-- float keys equivalent to int
local f={}; f[1.0]="one"; print(f[1], #f)          -- one 1
f[2]="two"; print(f[2.0])                           -- two
-- table.sort over array part
local srt={5,3,1,4,2}; table.sort(srt); print(table.concat(srt,","))  -- 1,2,3,4,5
-- table.unpack
print(table.unpack({100,200,300}))                 -- 100 200 300
-- clear by setting all to nil from top
local e={1,2,3}; e[3]=nil; e[2]=nil; e[1]=nil; print(#e, next(e))  -- 0 nil
-- big-ish sequential (within array cap)
local g={}; for i=1,100000 do g[i]=i end; local sum=0; for i=1,100000 do sum=sum+g[i] end; print(sum)  -- 5000050000
