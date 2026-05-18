-- Long-bracket strings and long comments — level 0 and level N.
-- Per Lua 5.5: an opening "[" + N "="s + "[" must close with the matching
-- N. A leading newline immediately after the opener is stripped.

-- Level 0 (existing).
print([[ plain ]])                       --  plain
print(#[[ab]])                           -- 2
print([[]])                              -- (empty)

-- Level 1: enclosed text may contain bare "]]".
print([=[ outer ]] ]=])                  --  outer ]]

-- Level 2: enclosed text may contain "]=]".
print([==[ a ]] b ]=] c ]==])            --  a ]] b ]=] c

-- Deep nesting.
print([===[ deep ]====] ]===])           --  deep ]====]

-- Leading newline stripped immediately after opener.
print([[
no leading newline]])                    -- no leading newline
print([==[
also stripped]==])                       -- also stripped

-- Multi-line bodies preserve internal newlines.
print([[a
b
c]])                                     -- a\nb\nc

-- Long comment, level 0.
print("alpha")
--[[ ignored ]]
print("beta")

-- Long comment, level N (can contain "]]").
print("gamma")
--[=[ this comment has ]] in it ]=]
print("delta")

-- Long comment, level 2.
--[==[ a ]] b ]==]
print("epsilon")

-- Long bracket as expression in a function call without parens (Lua sugar).
print [[paren-less]]                      -- paren-less
print [==[also works]==]                  -- also works
