-- Bisection method for solving non-linear equations.
-- Adapted for lua2wasm: globals are explicitly declared up front; everything
-- else is byte-for-byte the original.

global delta = 1e-6
global n
global bisect
global solve
global f

function bisect(f,a,b,fa,fb)
 local c=(a+b)/2
 io.write(n," c=",c," a=",a," b=",b,"\n")
 if c==a or c==b or math.abs(a-b)<delta then return c,b-a end
 n=n+1
 local fc=f(c)
 if fa*fc<0 then return bisect(f,a,c,fa,fc) else return bisect(f,c,b,fc,fb) end
end

function solve(f,a,b)
 n=0
 local z,e=bisect(f,a,b,f(a),f(b))
 io.write(string.format("after %d steps, root is %.17g with error %.1e, f=%.1e\n",n,z,e,f(z)))
end

function f(x)
 return x*x*x-x-1
end

solve(f,1,2)
