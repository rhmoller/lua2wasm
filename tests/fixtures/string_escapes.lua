-- String escapes per Lua 5.5 §3.1.

-- Standard single-char escapes.
print(#"\n\t\r")                          -- 3
print(string.byte("\n"))                  -- 10
print(string.byte("\t"))                  -- 9
print(string.byte("\a"))                  -- 7
print(string.byte("\b"))                  -- 8
print(string.byte("\f"))                  -- 12
print(string.byte("\v"))                  -- 11
print("\\quote\\")                        -- \quote\
print("\"inner\"")                        -- "inner"
print('inner')                            -- inner
print(#"\0", string.byte("\0"))           -- 1   0

-- \xHH (exactly two hex digits).
print(string.byte("\x41"))                -- 65 'A'
print(string.byte("\xff"))                -- 255
print(string.byte("\xFF"))                -- 255

-- \ddd (1-3 decimal digits, must fit in a byte).
print(string.byte("\65"))                 -- 65
print(string.byte("\065"))                -- 65
print(string.byte("\1"))                  -- 1
print(string.byte("\255"))                -- 255

-- \z skips a run of whitespace including newlines.
print("abc\z      def")                   -- abcdef
print("ab\z

         cd")                             -- abcd
print(#"a\z   b")                         -- 2

-- \u{N} encodes a Unicode codepoint as UTF-8.
print(#"\u{2603}")                        -- 3 (snowman, 3-byte UTF-8)
print(#"\u{1F600}")                       -- 4 (emoji)
print("\u{48}\u{69}\u{21}")               -- Hi!

-- \<newline> line continuation. Any CR/LF variant collapses to one \n.
print("first\
second")                                  -- first<NL>second
print(#"x\
y")                                       -- 3 (x, \n, y)
