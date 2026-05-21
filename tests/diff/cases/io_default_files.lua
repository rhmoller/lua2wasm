-- io.input() / io.output() with no argument return the current default input
-- and output file handles (initially io.stdin / io.stdout). io.write routes
-- through the default output file.
print(io.output() == io.stdout)
print(io.input() == io.stdin)
io.write("hello\n")
print(io.type(io.output()))
