;; Lua patterns: the matcher and string.find / match / gmatch / gsub.

  ;; --- Lua patterns: helpers (step 1 of milestone 20) ---
  ;;
  ;; See docs/design/20-lua-patterns.md for the full design. These three
  ;; helpers are the bytewise primitives the recursive $match_pat will
  ;; sit on top of in step 2:
  ;;   $match_class — test a byte against a %X char-class letter
  ;;   $match_set   — test a byte against a [...] set (with ^ negation,
  ;;                  %X member classes, and a-z ranges)
  ;;   $item_end    — return the pattern position right after the item
  ;;                  starting at $ppos (NOT including the quantifier)
  ;;   $match_one_item — test a byte against the matchable item at $ppos

  ;; Lowercase letter -> positive predicate, uppercase -> negation.
  ;; A non-class letter (anything outside a/A d/D l/L u/U w/W x/X
  ;; s/S c/C p/P g/G) falls back to a literal comparison so `%(` matches
  ;; '(' etc.
  (func $match_class (param $byte i32) (param $letter i32) (result i32)
    (local $lo i32) (local $hit i32) (local $neg i32)
    (local.set $lo (i32.or (local.get $letter) (i32.const 0x20)))
    ;; Detect uppercase letter (negation). A class letter is lowercase
    ;; OR an uppercase whose lower-form is a recognized class.
    (local.set $neg (i32.and
      (i32.ge_u (local.get $letter) (i32.const 65))
      (i32.le_u (local.get $letter) (i32.const 90))))
    ;; Compute the positive predicate for the lower-form letter.
    ;;   'a'/97 — letter
    ;;   'd'/100 — digit
    ;;   'l'/108 — lowercase
    ;;   'u'/117 — uppercase
    ;;   'w'/119 — alnum
    ;;   'x'/120 — hex digit
    ;;   's'/115 — space (incl. \t \n \v \f \r)
    ;;   'c'/99 — control (0..31 or 127)
    ;;   'p'/112 — punctuation (printable, non-alnum, non-space)
    ;;   'g'/103 — printable non-space (0x21..0x7E)
    (local.set $hit (i32.const 0))
    (if (i32.eq (local.get $lo) (i32.const 100))                ;; 'd'
      (then (local.set $hit (i32.and (i32.ge_u (local.get $byte) (i32.const 48))
                                      (i32.le_u (local.get $byte) (i32.const 57)))))
      (else (if (i32.eq (local.get $lo) (i32.const 97))         ;; 'a'
        (then (local.set $hit (i32.or
          (i32.and (i32.ge_u (local.get $byte) (i32.const 65))
                   (i32.le_u (local.get $byte) (i32.const 90)))
          (i32.and (i32.ge_u (local.get $byte) (i32.const 97))
                   (i32.le_u (local.get $byte) (i32.const 122))))))
        (else (if (i32.eq (local.get $lo) (i32.const 108))      ;; 'l'
          (then (local.set $hit (i32.and (i32.ge_u (local.get $byte) (i32.const 97))
                                          (i32.le_u (local.get $byte) (i32.const 122)))))
          (else (if (i32.eq (local.get $lo) (i32.const 117))    ;; 'u'
            (then (local.set $hit (i32.and (i32.ge_u (local.get $byte) (i32.const 65))
                                            (i32.le_u (local.get $byte) (i32.const 90)))))
            (else (if (i32.eq (local.get $lo) (i32.const 119))  ;; 'w'
              (then (local.set $hit (i32.or
                (i32.or
                  (i32.and (i32.ge_u (local.get $byte) (i32.const 48))
                           (i32.le_u (local.get $byte) (i32.const 57)))
                  (i32.and (i32.ge_u (local.get $byte) (i32.const 65))
                           (i32.le_u (local.get $byte) (i32.const 90))))
                (i32.and (i32.ge_u (local.get $byte) (i32.const 97))
                         (i32.le_u (local.get $byte) (i32.const 122))))))
              (else (if (i32.eq (local.get $lo) (i32.const 120)) ;; 'x'
                (then (local.set $hit (i32.or
                  (i32.or
                    (i32.and (i32.ge_u (local.get $byte) (i32.const 48))
                             (i32.le_u (local.get $byte) (i32.const 57)))
                    (i32.and (i32.ge_u (local.get $byte) (i32.const 97))
                             (i32.le_u (local.get $byte) (i32.const 102))))
                  (i32.and (i32.ge_u (local.get $byte) (i32.const 65))
                           (i32.le_u (local.get $byte) (i32.const 70))))))
                (else (if (i32.eq (local.get $lo) (i32.const 115)) ;; 's'
                  (then (local.set $hit (i32.or
                    (i32.eq (local.get $byte) (i32.const 32))
                    (i32.and (i32.ge_u (local.get $byte) (i32.const 9))
                             (i32.le_u (local.get $byte) (i32.const 13))))))
                  (else (if (i32.eq (local.get $lo) (i32.const 99)) ;; 'c'
                    (then (local.set $hit (i32.or
                      (i32.lt_u (local.get $byte) (i32.const 32))
                      (i32.eq (local.get $byte) (i32.const 127)))))
                    (else (if (i32.eq (local.get $lo) (i32.const 103)) ;; 'g'
                      (then (local.set $hit (i32.and
                        (i32.ge_u (local.get $byte) (i32.const 33))
                        (i32.le_u (local.get $byte) (i32.const 126)))))
                      (else (if (i32.eq (local.get $lo) (i32.const 112)) ;; 'p'
                        (then (local.set $hit (i32.and
                          (i32.and (i32.ge_u (local.get $byte) (i32.const 33))
                                   (i32.le_u (local.get $byte) (i32.const 126)))
                          (i32.eqz
                            ;; not alnum
                            (i32.or (i32.or
                              (i32.and (i32.ge_u (local.get $byte) (i32.const 48))
                                       (i32.le_u (local.get $byte) (i32.const 57)))
                              (i32.and (i32.ge_u (local.get $byte) (i32.const 65))
                                       (i32.le_u (local.get $byte) (i32.const 90))))
                              (i32.and (i32.ge_u (local.get $byte) (i32.const 97))
                                       (i32.le_u (local.get $byte) (i32.const 122))))))))
                        (else (if (i32.eq (local.get $lo) (i32.const 122)) ;; 'z'
                          (then (local.set $hit (i32.eqz (local.get $byte))))
                          (else
                            ;; Unrecognized class letter — literal compare.
                            (return (i32.eq (local.get $byte) (local.get $letter)))))))))))))))))))))))))
    (if (local.get $neg)
      (then (return (i32.eqz (local.get $hit)))))
    (local.get $hit))

  ;; Test $byte against the set whose '[' is at $lpos. Walks the body
  ;; until the matching ']' (per pattern rules, the first body byte —
  ;; possibly after a '^' — may itself be ']' as a literal). Returns 1
  ;; on match, 0 otherwise.
  (func $match_set (param $byte i32) (param $pat (ref $LuaArr))
                   (param $lpos i32) (result i32)
    (local $n i32) (local $i i32) (local $neg i32)
    (local $b i32) (local $a i32) (local $c i32)
    (local $first i32) (local $hit i32)
    (local.set $n (array.len (local.get $pat)))
    (local.set $i (i32.add (local.get $lpos) (i32.const 1)))
    ;; Negation: [^...]
    (if (i32.and (i32.lt_s (local.get $i) (local.get $n))
                 (i32.eq (array.get_u $LuaArr (local.get $pat) (local.get $i))
                         (i32.const 94)))   ;; '^'
      (then (local.set $neg (i32.const 1))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
    (local.set $first (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (array.get_u $LuaArr (local.get $pat) (local.get $i)))
      ;; ']' closes the set unless it's the very first body byte.
      (if (i32.and (i32.eq (local.get $b) (i32.const 93))   ;; ']'
                   (i32.eqz (local.get $first)))
        (then (br $done)))
      (local.set $first (i32.const 0))
      (if (i32.eq (local.get $b) (i32.const 37))            ;; '%'
        (then
          (if (i32.ge_s (i32.add (local.get $i) (i32.const 1)) (local.get $n))
            (then (br $done)))
          (if (call $match_class (local.get $byte)
                (array.get_u $LuaArr (local.get $pat)
                  (i32.add (local.get $i) (i32.const 1))))
            (then (local.set $hit (i32.const 1)) (br $done)))
          (local.set $i (i32.add (local.get $i) (i32.const 2)))
          (br $lp)))
      ;; range a-z (only if pat[i+1] == '-' AND pat[i+2] != ']'). WAT's
      ;; i32.and isn't short-circuit, so the two reads must be guarded
      ;; with nested if to stay in bounds near the set's closing ']'.
      (if (i32.lt_s (i32.add (local.get $i) (i32.const 2)) (local.get $n))
        (then
          (if (i32.eq (array.get_u $LuaArr (local.get $pat)
                        (i32.add (local.get $i) (i32.const 1)))
                      (i32.const 45))                  ;; '-'
            (then
              (local.set $c (array.get_u $LuaArr (local.get $pat)
                              (i32.add (local.get $i) (i32.const 2))))
              (if (i32.ne (local.get $c) (i32.const 93))   ;; not ']'
                (then
                  (local.set $a (local.get $b))
                  (if (i32.and (i32.ge_u (local.get $byte) (local.get $a))
                               (i32.le_u (local.get $byte) (local.get $c)))
                    (then (local.set $hit (i32.const 1)) (br $done)))
                  (local.set $i (i32.add (local.get $i) (i32.const 3)))
                  (br $lp)))))))
      ;; literal
      (if (i32.eq (local.get $byte) (local.get $b))
        (then (local.set $hit (i32.const 1)) (br $done)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (if (local.get $neg)
      (then (return (i32.eqz (local.get $hit)))))
    (local.get $hit))

  ;; Returns the pattern position right after the matchable item at
  ;; $ppos (NOT including any quantifier suffix). Item kinds:
  ;;   literal       end = ppos + 1
  ;;   '.'           end = ppos + 1
  ;;   '%X'          end = ppos + 2
  ;;   '[...]'       end = position of the byte after the closing ']'
  (func $item_end (param $pat (ref $LuaArr)) (param $ppos i32) (result i32)
    (local $b i32) (local $n i32) (local $i i32) (local $first i32)
    (local.set $n (array.len (local.get $pat)))
    (local.set $b (array.get_u $LuaArr (local.get $pat) (local.get $ppos)))
    (if (i32.eq (local.get $b) (i32.const 37))      ;; '%'
      (then (return (i32.add (local.get $ppos) (i32.const 2)))))
    (if (i32.ne (local.get $b) (i32.const 91))      ;; '['
      (then (return (i32.add (local.get $ppos) (i32.const 1)))))
    ;; Walk a set body to its closing ']'.
    (local.set $i (i32.add (local.get $ppos) (i32.const 1)))
    (if (i32.and (i32.lt_s (local.get $i) (local.get $n))
                 (i32.eq (array.get_u $LuaArr (local.get $pat) (local.get $i))
                         (i32.const 94)))
      (then (local.set $i (i32.add (local.get $i) (i32.const 1)))))
    (local.set $first (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (array.get_u $LuaArr (local.get $pat) (local.get $i)))
      (if (i32.and (i32.eq (local.get $b) (i32.const 93))
                   (i32.eqz (local.get $first)))
        (then (return (i32.add (local.get $i) (i32.const 1)))))
      (local.set $first (i32.const 0))
      (if (i32.eq (local.get $b) (i32.const 37))
        (then (local.set $i (i32.add (local.get $i) (i32.const 2))))
        (else (local.set $i (i32.add (local.get $i) (i32.const 1)))))
      (br $lp)))
    ;; Unterminated set — return end of pattern. The matcher caller
    ;; will fail naturally on the unmatched item.
    (local.get $n))

  ;; Test $byte against the matchable item at $ppos. Dispatches on
  ;; pat[ppos]: '.', '%X', '[...]', or a literal byte.
  (func $match_one_item (param $byte i32) (param $pat (ref $LuaArr))
                         (param $ppos i32) (result i32)
    (local $b i32)
    (local.set $b (array.get_u $LuaArr (local.get $pat) (local.get $ppos)))
    (if (i32.eq (local.get $b) (i32.const 46))      ;; '.'
      (then (return (i32.const 1))))
    (if (i32.eq (local.get $b) (i32.const 37))      ;; '%'
      (then (return (call $match_class (local.get $byte)
        (array.get_u $LuaArr (local.get $pat)
          (i32.add (local.get $ppos) (i32.const 1)))))))
    (if (i32.eq (local.get $b) (i32.const 91))      ;; '['
      (then (return (call $match_set (local.get $byte) (local.get $pat) (local.get $ppos)))))
    (i32.eq (local.get $byte) (local.get $b)))

  ;; --- Lua patterns: $match_pat core (steps 2-3 of milestone 20) ---
  ;;
  ;; Recursive backtracking matcher. Walks $pat from $ppos and $sub from
  ;; $spos. Returns multi-value (end_spos, ncaps_out):
  ;;   end_spos = the subject position one past the last matched byte
  ;;              on success, OR -1 on failure
  ;;   ncaps_out = number of captures recorded in $caps after a
  ;;               successful match (caller ignores it on failure)
  ;;
  ;; Captures live in $caps as (start, len) i32 pairs. len sentinels:
  ;;   -1 = open substring capture; -2 = position capture.
  ;; A close (')') walks back from ncaps-1 to find the most recent open
  ;; and writes its length; the write is reverted if the recursive
  ;; continuation fails (the parent of this call may re-enter the close
  ;; from a different backtrack path).
  ;;
  ;; Quantifiers (* + - ?) apply to a single matchable item per spec
  ;; (NOT to groups, back-refs, %bxy, or %f[set]).
  (func $match_pat
    (param $sub (ref $LuaArr)) (param $spos i32)
    (param $pat (ref $LuaArr)) (param $ppos i32)
    (param $caps (ref $CapArr)) (param $ncaps i32)
    (result i32 i32)
    (local $n_pat i32) (local $n_sub i32) (local $b i32) (local $b2 i32)
    (local $item_end_pos i32) (local $quant i32) (local $next_ppos i32)
    (local $k i32) (local $min_k i32) (local $r i32) (local $r_n i32)
    (local $idx i32) (local $cap_start i32) (local $cap_len i32)
    (local.set $n_pat (array.len (local.get $pat)))
    (local.set $n_sub (array.len (local.get $sub)))
    ;; Base: end of pattern → success.
    (if (i32.ge_s (local.get $ppos) (local.get $n_pat))
      (then (return (local.get $spos) (local.get $ncaps))))
    (local.set $b (array.get_u $LuaArr (local.get $pat) (local.get $ppos)))
    ;; `$` at the final pattern position → anchor-to-end.
    (if (i32.and (i32.eq (local.get $b) (i32.const 36))            ;; '$'
                 (i32.eq (i32.add (local.get $ppos) (i32.const 1))
                         (local.get $n_pat)))
      (then
        (if (i32.eq (local.get $spos) (local.get $n_sub))
          (then (return (local.get $spos) (local.get $ncaps))))
        (return (i32.const -1) (local.get $ncaps))))
    ;; '(' open: position capture if next char is ')'; else substring.
    (if (i32.eq (local.get $b) (i32.const 40))                     ;; '('
      (then
        (local.set $b2 (i32.const 0))
        (if (i32.lt_s (i32.add (local.get $ppos) (i32.const 1))
                       (local.get $n_pat))
          (then (local.set $b2 (array.get_u $LuaArr (local.get $pat)
                  (i32.add (local.get $ppos) (i32.const 1))))))
        (array.set $CapArr (local.get $caps)
          (i32.mul (local.get $ncaps) (i32.const 2)) (local.get $spos))
        (if (i32.eq (local.get $b2) (i32.const 41))                ;; ')'
          (then
            ;; position capture
            (array.set $CapArr (local.get $caps)
              (i32.add (i32.mul (local.get $ncaps) (i32.const 2)) (i32.const 1))
              (i32.const -2))
            (return_call $match_pat (local.get $sub) (local.get $spos)
              (local.get $pat) (i32.add (local.get $ppos) (i32.const 2))
              (local.get $caps) (i32.add (local.get $ncaps) (i32.const 1)))))
        ;; substring capture (open)
        (array.set $CapArr (local.get $caps)
          (i32.add (i32.mul (local.get $ncaps) (i32.const 2)) (i32.const 1))
          (i32.const -1))
        (return_call $match_pat (local.get $sub) (local.get $spos)
          (local.get $pat) (i32.add (local.get $ppos) (i32.const 1))
          (local.get $caps) (i32.add (local.get $ncaps) (i32.const 1)))))
    ;; ')' close: find the most recent open and fix it up; restore on
    ;; failure so a different backtrack path can still close it.
    (if (i32.eq (local.get $b) (i32.const 41))                     ;; ')'
      (then
        (local.set $idx (i32.sub (local.get $ncaps) (i32.const 1)))
        (block $found (loop $scan
          (if (i32.lt_s (local.get $idx) (i32.const 0))
            (then (return (i32.const -1) (local.get $ncaps))))
          (if (i32.eq (array.get $CapArr (local.get $caps)
                        (i32.add (i32.mul (local.get $idx) (i32.const 2))
                                 (i32.const 1)))
                      (i32.const -1))
            (then (br $found)))
          (local.set $idx (i32.sub (local.get $idx) (i32.const 1)))
          (br $scan)))
        ;; $idx is the open capture to close. Its length cell is the open
        ;; sentinel (-1) by construction: the scan above selected this capture
        ;; precisely because that cell held -1. So on a failed close we rewind
        ;; straight back to -1 — no saved value to track.
        (array.set $CapArr (local.get $caps)
          (i32.add (i32.mul (local.get $idx) (i32.const 2)) (i32.const 1))
          (i32.sub (local.get $spos)
            (array.get $CapArr (local.get $caps)
              (i32.mul (local.get $idx) (i32.const 2)))))
        (call $match_pat (local.get $sub) (local.get $spos)
          (local.get $pat) (i32.add (local.get $ppos) (i32.const 1))
          (local.get $caps) (local.get $ncaps))
        (local.set $r_n)
        (local.set $r)
        (if (i32.ge_s (local.get $r) (i32.const 0))
          (then (return (local.get $r) (local.get $r_n))))
        ;; rewind the close back to the open sentinel
        (array.set $CapArr (local.get $caps)
          (i32.add (i32.mul (local.get $idx) (i32.const 2)) (i32.const 1))
          (i32.const -1))
        (return (i32.const -1) (local.get $ncaps))))
    ;; '%n' back-reference (n=1..9), '%bxy' balanced match, '%f[set]'
    ;; frontier.
    (if (i32.eq (local.get $b) (i32.const 37))                     ;; '%'
      (then
        (if (i32.lt_s (i32.add (local.get $ppos) (i32.const 1))
                       (local.get $n_pat))
          (then
            (local.set $b2 (array.get_u $LuaArr (local.get $pat)
              (i32.add (local.get $ppos) (i32.const 1))))
            ;; %n back-reference
            (if (i32.and (i32.ge_u (local.get $b2) (i32.const 49))
                         (i32.le_u (local.get $b2) (i32.const 57)))
              (then
                (local.set $idx (i32.sub (local.get $b2) (i32.const 49)))
                (if (i32.ge_s (local.get $idx) (local.get $ncaps))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (local.set $cap_start (array.get $CapArr (local.get $caps)
                  (i32.mul (local.get $idx) (i32.const 2))))
                (local.set $cap_len (array.get $CapArr (local.get $caps)
                  (i32.add (i32.mul (local.get $idx) (i32.const 2)) (i32.const 1))))
                (if (i32.lt_s (local.get $cap_len) (i32.const 0))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (if (i32.gt_s (i32.add (local.get $spos) (local.get $cap_len))
                               (local.get $n_sub))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (local.set $k (i32.const 0))
                (block $bdone (loop $bcmp
                  (br_if $bdone (i32.ge_s (local.get $k) (local.get $cap_len)))
                  (if (i32.ne
                        (array.get_u $LuaArr (local.get $sub)
                          (i32.add (local.get $spos) (local.get $k)))
                        (array.get_u $LuaArr (local.get $sub)
                          (i32.add (local.get $cap_start) (local.get $k))))
                    (then (return (i32.const -1) (local.get $ncaps))))
                  (local.set $k (i32.add (local.get $k) (i32.const 1)))
                  (br $bcmp)))
                (return_call $match_pat (local.get $sub)
                  (i32.add (local.get $spos) (local.get $cap_len))
                  (local.get $pat) (i32.add (local.get $ppos) (i32.const 2))
                  (local.get $caps) (local.get $ncaps))))
            ;; %bxy balanced match. open = pat[ppos+2], close = pat[ppos+3].
            (if (i32.eq (local.get $b2) (i32.const 98))            ;; 'b'
              (then
                (if (i32.gt_s (i32.add (local.get $ppos) (i32.const 4))
                               (local.get $n_pat))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (local.set $cap_start (array.get_u $LuaArr (local.get $pat)
                  (i32.add (local.get $ppos) (i32.const 2))))
                (local.set $cap_len (array.get_u $LuaArr (local.get $pat)
                  (i32.add (local.get $ppos) (i32.const 3))))
                (if (i32.ge_s (local.get $spos) (local.get $n_sub))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (if (i32.ne (array.get_u $LuaArr (local.get $sub) (local.get $spos))
                            (local.get $cap_start))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (local.set $k (i32.add (local.get $spos) (i32.const 1)))
                (local.set $idx (i32.const 1))                     ;; depth
                (block $bdone (loop $bscan
                  (br_if $bdone (i32.ge_s (local.get $k) (local.get $n_sub)))
                  (local.set $b (array.get_u $LuaArr (local.get $sub) (local.get $k)))
                  (if (i32.eq (local.get $b) (local.get $cap_start))
                    (then (local.set $idx (i32.add (local.get $idx) (i32.const 1)))))
                  (if (i32.eq (local.get $b) (local.get $cap_len))
                    (then
                      (local.set $idx (i32.sub (local.get $idx) (i32.const 1)))
                      (if (i32.eqz (local.get $idx))
                        (then
                          (return_call $match_pat (local.get $sub)
                            (i32.add (local.get $k) (i32.const 1))
                            (local.get $pat)
                            (i32.add (local.get $ppos) (i32.const 4))
                            (local.get $caps) (local.get $ncaps))))))
                  (local.set $k (i32.add (local.get $k) (i32.const 1)))
                  (br $bscan)))
                (return (i32.const -1) (local.get $ncaps))))
            ;; %f[set] frontier — matches empty at spos iff
            ;; sub[spos-1] is NOT in [set] AND sub[spos] IS in [set].
            ;; (Treat sub[-1] and sub[n_sub] as 0.)
            (if (i32.eq (local.get $b2) (i32.const 102))           ;; 'f'
              (then
                (if (i32.ge_s (i32.add (local.get $ppos) (i32.const 2))
                               (local.get $n_pat))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (if (i32.ne (array.get_u $LuaArr (local.get $pat)
                              (i32.add (local.get $ppos) (i32.const 2)))
                            (i32.const 91))                        ;; '['
                  (then (return (i32.const -1) (local.get $ncaps))))
                (local.set $idx (i32.add (local.get $ppos) (i32.const 2)))
                (local.set $cap_len (call $item_end (local.get $pat) (local.get $idx)))
                (local.set $cap_start (i32.const 0))
                (if (i32.gt_s (local.get $spos) (i32.const 0))
                  (then (local.set $cap_start
                    (array.get_u $LuaArr (local.get $sub)
                      (i32.sub (local.get $spos) (i32.const 1))))))
                (local.set $b (i32.const 0))
                (if (i32.lt_s (local.get $spos) (local.get $n_sub))
                  (then (local.set $b
                    (array.get_u $LuaArr (local.get $sub) (local.get $spos)))))
                (if (call $match_set (local.get $cap_start) (local.get $pat) (local.get $idx))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (if (i32.eqz (call $match_set (local.get $b) (local.get $pat) (local.get $idx)))
                  (then (return (i32.const -1) (local.get $ncaps))))
                (return_call $match_pat (local.get $sub) (local.get $spos)
                  (local.get $pat) (local.get $cap_len)
                  (local.get $caps) (local.get $ncaps))))))))
    ;; Decode the matchable item ending at $item_end_pos. Read quantifier
    ;; (if any) immediately after.
    (local.set $item_end_pos (call $item_end (local.get $pat) (local.get $ppos)))
    (local.set $quant (i32.const 0))
    (if (i32.lt_s (local.get $item_end_pos) (local.get $n_pat))
      (then
        (local.set $b (array.get_u $LuaArr (local.get $pat) (local.get $item_end_pos)))
        (if (i32.or (i32.eq (local.get $b) (i32.const 42))         ;; '*'
            (i32.or (i32.eq (local.get $b) (i32.const 43))         ;; '+'
            (i32.or (i32.eq (local.get $b) (i32.const 45))         ;; '-'
                    (i32.eq (local.get $b) (i32.const 63)))))      ;; '?'
          (then (local.set $quant (local.get $b))))))
    ;; Pattern position to continue at after this item.
    (if (i32.eqz (local.get $quant))
      (then (local.set $next_ppos (local.get $item_end_pos)))
      (else (local.set $next_ppos
              (i32.add (local.get $item_end_pos) (i32.const 1)))))
    ;; Quantifier-specific dispatch.
    (if (i32.eq (local.get $quant) (i32.const 63))                 ;; '?'
      (then
        ;; i32.and is eager — short-circuit via nested if so we don't
        ;; read sub[spos] when spos == n_sub.
        (if (i32.lt_s (local.get $spos) (local.get $n_sub))
          (then
            (if (call $match_one_item
                  (array.get_u $LuaArr (local.get $sub) (local.get $spos))
                  (local.get $pat) (local.get $ppos))
              (then
                (call $match_pat
                  (local.get $sub) (i32.add (local.get $spos) (i32.const 1))
                  (local.get $pat) (local.get $next_ppos)
                  (local.get $caps) (local.get $ncaps))
                (local.set $r_n) (local.set $r)
                (if (i32.ge_s (local.get $r) (i32.const 0))
                  (then (return (local.get $r) (local.get $r_n))))))))
        (return_call $match_pat (local.get $sub) (local.get $spos)
          (local.get $pat) (local.get $next_ppos)
          (local.get $caps) (local.get $ncaps))))
    (if (i32.eq (local.get $quant) (i32.const 45))                 ;; '-' lazy
      (then
        (local.set $k (i32.const 0))
        (loop $lazy
          (call $match_pat
            (local.get $sub) (i32.add (local.get $spos) (local.get $k))
            (local.get $pat) (local.get $next_ppos)
            (local.get $caps) (local.get $ncaps))
          (local.set $r_n) (local.set $r)
          (if (i32.ge_s (local.get $r) (i32.const 0))
            (then (return (local.get $r) (local.get $r_n))))
          (if (i32.ge_s (i32.add (local.get $spos) (local.get $k))
                         (local.get $n_sub))
            (then (return (i32.const -1) (local.get $ncaps))))
          (if (i32.eqz (call $match_one_item
                (array.get_u $LuaArr (local.get $sub)
                  (i32.add (local.get $spos) (local.get $k)))
                (local.get $pat) (local.get $ppos)))
            (then (return (i32.const -1) (local.get $ncaps))))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $lazy))
        (unreachable)))
    (if (i32.or (i32.eq (local.get $quant) (i32.const 42))         ;; '*' or '+'
                (i32.eq (local.get $quant) (i32.const 43)))
      (then
        (local.set $k (i32.const 0))
        (block $count_done
          (loop $count
            (br_if $count_done (i32.ge_s
              (i32.add (local.get $spos) (local.get $k))
              (local.get $n_sub)))
            (br_if $count_done (i32.eqz (call $match_one_item
              (array.get_u $LuaArr (local.get $sub)
                (i32.add (local.get $spos) (local.get $k)))
              (local.get $pat) (local.get $ppos))))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $count)))
        (local.set $min_k (i32.const 0))
        (if (i32.eq (local.get $quant) (i32.const 43))
          (then (local.set $min_k (i32.const 1))))
        (if (i32.lt_s (local.get $k) (local.get $min_k))
          (then (return (i32.const -1) (local.get $ncaps))))
        (loop $backoff
          (call $match_pat
            (local.get $sub) (i32.add (local.get $spos) (local.get $k))
            (local.get $pat) (local.get $next_ppos)
            (local.get $caps) (local.get $ncaps))
          (local.set $r_n) (local.set $r)
          (if (i32.ge_s (local.get $r) (i32.const 0))
            (then (return (local.get $r) (local.get $r_n))))
          (if (i32.le_s (local.get $k) (local.get $min_k))
            (then (return (i32.const -1) (local.get $ncaps))))
          (local.set $k (i32.sub (local.get $k) (i32.const 1)))
          (br $backoff))
        (unreachable)))
    ;; No quantifier: match exactly once.
    (if (i32.ge_s (local.get $spos) (local.get $n_sub))
      (then (return (i32.const -1) (local.get $ncaps))))
    (if (i32.eqz (call $match_one_item
          (array.get_u $LuaArr (local.get $sub) (local.get $spos))
          (local.get $pat) (local.get $ppos)))
      (then (return (i32.const -1) (local.get $ncaps))))
    (return_call $match_pat
      (local.get $sub) (i32.add (local.get $spos) (i32.const 1))
      (local.get $pat) (local.get $next_ppos)
      (local.get $caps) (local.get $ncaps)))

  ;; Materialize one capture as an anyref Lua value:
  ;;   position capture (len == -2) → 1-based integer
  ;;   substring capture (len >= 0) → $LuaString of sub[start..start+len]
  ;; Open captures (len == -1) shouldn't survive into the result.
  (func $cap_to_value (param $sub (ref $LuaArr))
                      (param $caps (ref $CapArr)) (param $idx i32)
                      (result anyref)
    (local $start i32) (local $len i32) (local $bytes (ref $LuaArr))
    (local.set $start (array.get $CapArr (local.get $caps)
      (i32.mul (local.get $idx) (i32.const 2))))
    (local.set $len (array.get $CapArr (local.get $caps)
      (i32.add (i32.mul (local.get $idx) (i32.const 2)) (i32.const 1))))
    (if (i32.eq (local.get $len) (i32.const -2))
      (then (return (call $make_int (i64.extend_i32_s
        (i32.add (local.get $start) (i32.const 1)))))))
    (local.set $bytes (array.new $LuaArr (i32.const 0) (local.get $len)))
    (array.copy $LuaArr $LuaArr
      (local.get $bytes) (i32.const 0)
      (local.get $sub) (local.get $start) (local.get $len))
    (struct.new $LuaString (local.get $bytes) (i32.const 0)))

  ;; Plain byte-for-byte search: returns the 0-based end-position of
  ;; the first occurrence of $needle starting at $start, or -1.
  (func $plain_find
    (param $hay (ref $LuaArr)) (param $start i32)
    (param $needle (ref $LuaArr)) (result i32)
    (local $n_hay i32) (local $n_need i32) (local $sp i32) (local $k i32)
    (local.set $n_hay (array.len (local.get $hay)))
    (local.set $n_need (array.len (local.get $needle)))
    (if (i32.eqz (local.get $n_need))
      (then (return (local.get $start))))
    (local.set $sp (local.get $start))
    (block $done (loop $outer
      (br_if $done (i32.gt_s (i32.add (local.get $sp) (local.get $n_need))
                              (local.get $n_hay)))
      (local.set $k (i32.const 0))
      (block $no_match (loop $inner
        (br_if $no_match (i32.ge_s (local.get $k) (local.get $n_need)))
        (br_if $no_match (i32.ne
          (array.get_u $LuaArr (local.get $hay)
            (i32.add (local.get $sp) (local.get $k)))
          (array.get_u $LuaArr (local.get $needle) (local.get $k))))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $inner)))
      (if (i32.eq (local.get $k) (local.get $n_need))
        (then (return (i32.add (local.get $sp) (local.get $n_need)))))
      (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
      (br $outer)))
    (i32.const -1))

  ;; --- shared pattern-search prologue helpers (find/match/gsub) ---

  ;; Anchor: returns 1 if the pattern begins with '^' (matching then runs
  ;; from ppos 1 and only at the initial subject position), else 0. The
  ;; length guard keeps the pat[0] read off an empty pattern (i32.and is
  ;; not short-circuit, so find("","") would otherwise read OOB).
  (func $pat_anchor_start (param $pat (ref $LuaArr)) (result i32)
    (if (result i32) (i32.gt_s (array.len (local.get $pat)) (i32.const 0))
      (then (i32.eq (array.get_u $LuaArr (local.get $pat) (i32.const 0))
                    (i32.const 94)))   ;; '^'
      (else (i32.const 0))))

  ;; Normalize a 1-based string index argument (find/match `init`): a
  ;; negative value counts from the end, and anything below 1 clamps to 1.
  ;; Callers still reject init > n+1 separately, since that is an early
  ;; "no match" return.
  (func $norm_str_init (param $init i32) (param $n i32) (result i32)
    (if (i32.lt_s (local.get $init) (i32.const 0))
      (then (local.set $init (i32.add (local.get $n)
                               (i32.add (local.get $init) (i32.const 1))))))
    (if (i32.lt_s (local.get $init) (i32.const 1))
      (then (local.set $init (i32.const 1))))
    (local.get $init))

  ;; string.find(s, pat [, init [, plain]]).
  ;; Returns (start, end, captures…) on success — 1-based positions of
  ;; the first and last matched bytes (or end < start for an empty
  ;; match). Returns nil on no match. With $plain truthy, $pat is
  ;; treated as a literal byte string (no pattern interpretation).
  (func $builtin_string_find (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $sub (ref $LuaArr)) (local $pat (ref $LuaArr))
    (local $n_sub i32) (local $n_pat i32) (local $nargs i32)
    (local $init i32) (local $anchored i32) (local $start_ppos i32)
    (local $sp i32) (local $end i32) (local $ncaps i32)
    (local $plain i32)
    (local $caps (ref $CapArr)) (local $out (ref $ArgArr)) (local $i i32)
    (local $arg0 anyref) (local $arg1 anyref)
    (local.set $arg0 (call $args_at (local.get $args) (i32.const 0)))
    (local.set $arg1 (call $args_at (local.get $args) (i32.const 1)))
    ;; Coerce numeric subject/pattern to strings (luaL_checkstring), like
    ;; string.match/gsub/gmatch; a non-coercible arg raises a catchable
    ;; "string expected" instead of trapping on ref.cast.
    (local.set $sub (call $str_bytes (call $arg_string (local.get $arg0))))
    (local.set $pat (call $str_bytes (call $arg_string (local.get $arg1))))
    (local.set $n_sub (array.len (local.get $sub)))
    (local.set $n_pat (array.len (local.get $pat)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $init (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $init (i32.wrap_i64
              (call $as_int_co (call $args_at (local.get $args) (i32.const 2)))))))
    (if (i32.gt_u (local.get $nargs) (i32.const 3))
      (then (local.set $plain (call $lua_truthy
              (call $args_at (local.get $args) (i32.const 3))))))
    (local.set $init (call $norm_str_init (local.get $init) (local.get $n_sub)))
    (if (i32.gt_s (local.get $init) (i32.add (local.get $n_sub) (i32.const 1)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    ;; Plain mode: literal substring search, no captures.
    (if (local.get $plain)
      (then
        (local.set $end (call $plain_find
          (local.get $sub) (i32.sub (local.get $init) (i32.const 1))
          (local.get $pat)))
        (if (i32.lt_s (local.get $end) (i32.const 0))
          (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
        (return (array.new_fixed $ArgArr 2
          (call $make_int (i64.extend_i32_s
            (i32.add (i32.sub (local.get $end) (local.get $n_pat)) (i32.const 1))))
          (call $make_int (i64.extend_i32_s (local.get $end)))))))
    (local.set $start_ppos (call $pat_anchor_start (local.get $pat)))
    (local.set $anchored (local.get $start_ppos))
    (local.set $sp (i32.sub (local.get $init) (i32.const 1)))
    (local.set $caps (array.new $CapArr (i32.const 0) (i32.const 64)))
    (block $search_done (loop $search
      (call $match_pat
        (local.get $sub) (local.get $sp)
        (local.get $pat) (local.get $start_ppos)
        (local.get $caps) (i32.const 0))
      (local.set $ncaps)
      (local.set $end)
      (if (i32.ge_s (local.get $end) (i32.const 0))
        (then
          ;; Build (start, end, cap1, cap2, ...)
          (local.set $out (array.new $ArgArr (ref.null any)
            (i32.add (i32.const 2) (local.get $ncaps))))
          (array.set $ArgArr (local.get $out) (i32.const 0)
            (call $make_int (i64.extend_i32_s
              (i32.add (local.get $sp) (i32.const 1)))))
          (array.set $ArgArr (local.get $out) (i32.const 1)
            (call $make_int (i64.extend_i32_s (local.get $end))))
          (local.set $i (i32.const 0))
          (block $cdone (loop $cp
            (br_if $cdone (i32.ge_s (local.get $i) (local.get $ncaps)))
            (array.set $ArgArr (local.get $out)
              (i32.add (local.get $i) (i32.const 2))
              (call $cap_to_value (local.get $sub) (local.get $caps) (local.get $i)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp)))
          (return (local.get $out))))
      (br_if $search_done (local.get $anchored))
      (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
      (br_if $search_done (i32.gt_s (local.get $sp) (local.get $n_sub)))
      (br $search)))
    (array.new_fixed $ArgArr 1 (ref.null any)))

  ;; string.match(s, pat [, init]).
  ;; Like find, but returns the captures (or the whole match if no
  ;; captures) instead of the position pair.
  (func $builtin_string_match (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $sub (ref $LuaArr)) (local $pat (ref $LuaArr))
    (local $n_sub i32) (local $n_pat i32) (local $nargs i32)
    (local $init i32) (local $anchored i32) (local $start_ppos i32)
    (local $sp i32) (local $end i32) (local $ncaps i32)
    (local $caps (ref $CapArr)) (local $out (ref $ArgArr)) (local $i i32)
    (local $whole (ref $LuaArr))
    (local.set $sub (call $str_bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $pat (call $str_bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $n_sub (array.len (local.get $sub)))
    (local.set $n_pat (array.len (local.get $pat)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $init (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $init (i32.wrap_i64
              (call $as_int_co (call $args_at (local.get $args) (i32.const 2)))))))
    (local.set $init (call $norm_str_init (local.get $init) (local.get $n_sub)))
    (if (i32.gt_s (local.get $init) (i32.add (local.get $n_sub) (i32.const 1)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $start_ppos (call $pat_anchor_start (local.get $pat)))
    (local.set $anchored (local.get $start_ppos))
    (local.set $sp (i32.sub (local.get $init) (i32.const 1)))
    (local.set $caps (array.new $CapArr (i32.const 0) (i32.const 64)))
    (block $search_done (loop $search
      (call $match_pat
        (local.get $sub) (local.get $sp)
        (local.get $pat) (local.get $start_ppos)
        (local.get $caps) (i32.const 0))
      (local.set $ncaps)
      (local.set $end)
      (if (i32.ge_s (local.get $end) (i32.const 0))
        (then
          (if (i32.eqz (local.get $ncaps))
            (then
              ;; No captures: return the whole match as a $LuaString.
              (local.set $whole (array.new $LuaArr (i32.const 0)
                (i32.sub (local.get $end) (local.get $sp))))
              (array.copy $LuaArr $LuaArr
                (local.get $whole) (i32.const 0)
                (local.get $sub) (local.get $sp)
                (i32.sub (local.get $end) (local.get $sp)))
              (return (array.new_fixed $ArgArr 1
                (struct.new $LuaString (local.get $whole) (i32.const 0))))))
          ;; One or more captures: return each.
          (local.set $out (array.new $ArgArr (ref.null any) (local.get $ncaps)))
          (local.set $i (i32.const 0))
          (block $cdone (loop $cp
            (br_if $cdone (i32.ge_s (local.get $i) (local.get $ncaps)))
            (array.set $ArgArr (local.get $out) (local.get $i)
              (call $cap_to_value (local.get $sub) (local.get $caps) (local.get $i)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp)))
          (return (local.get $out))))
      (br_if $search_done (local.get $anchored))
      (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
      (br_if $search_done (i32.gt_s (local.get $sp) (local.get $n_sub)))
      (br $search)))
    (array.new_fixed $ArgArr 1 (ref.null any)))

;; string.gmatch iterator step. Upvalues: (s, pat, src, lastmatch, caps).
  ;; Mirrors reference gmatch_aux: scan from src; accept a match only when
  ;; its end differs from the previous match's end ($lastmatch). That single
  ;; rule is what suppresses a spurious empty match immediately after another
  ;; match — e.g. ("a,b,,c"):gmatch("[^,]*") yields a,b,"",c, not a doubled
  ;; sequence. $lastmatch starts at -1 (no previous match). $gmatch_next
  ;; finds the next match and advances the state: the match's start and end
  ;; (-1: no more matches) and its capture count, the captures in the
  ;; iterator's own capture buffer (upvalue 4, reused from call to call).
  (func $gmatch_next (param $self (ref $LuaClosure)) (result i32 i32 i32)
    (local $upvals (ref $UpvalArr))
    (local $sub (ref $LuaArr)) (local $pat (ref $LuaArr))
    (local $n_sub i32) (local $sp i32) (local $end i32) (local $ncaps i32) (local $lastmatch i32)
    (local.set $upvals (struct.get $LuaClosure $upvals (local.get $self)))
    (local.set $sub (call $gmatch_subject (local.get $self)))
    (local.set $pat (call $str_bytes
      (ref.cast (ref $LuaString) (struct.get $Box $v (array.get $UpvalArr (local.get $upvals) (i32.const 1))))))
    (local.set $sp (i32.wrap_i64 (call $as_int
      (struct.get $Box $v (array.get $UpvalArr (local.get $upvals) (i32.const 2))))))
    (local.set $lastmatch (i32.wrap_i64 (call $as_int
      (struct.get $Box $v (array.get $UpvalArr (local.get $upvals) (i32.const 3))))))
    (local.set $n_sub (array.len (local.get $sub)))
    ;; gmatch does not honour '^' as an anchor; $match_pat is given ppos 0.
    (block $search_done (loop $search
      (br_if $search_done (i32.gt_s (local.get $sp) (local.get $n_sub)))
      (call $match_pat
        (local.get $sub) (local.get $sp)
        (local.get $pat) (i32.const 0)
        (call $gmatch_caps (local.get $self)) (i32.const 0))
      (local.set $ncaps)
      (local.set $end)
      (if (i32.and (i32.ge_s (local.get $end) (i32.const 0))
                   (i32.ne (local.get $end) (local.get $lastmatch)))
        (then
          ;; Accept: next scan resumes at $end; remember it as $lastmatch.
          (struct.set $Box $v
            (array.get $UpvalArr (local.get $upvals) (i32.const 2))
            (call $make_int (i64.extend_i32_s (local.get $end))))
          (struct.set $Box $v
            (array.get $UpvalArr (local.get $upvals) (i32.const 3))
            (call $make_int (i64.extend_i32_s (local.get $end))))
          (return (local.get $sp) (local.get $end) (local.get $ncaps))))
      (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
      (br $search)))
    (i32.const 0) (i32.const -1) (i32.const 0))
  (func $gmatch_subject (param $self (ref $LuaClosure)) (result (ref $LuaArr))
    (call $str_bytes (ref.cast (ref $LuaString) (struct.get $Box $v
      (array.get $UpvalArr (struct.get $LuaClosure $upvals (local.get $self)) (i32.const 0))))))
  (func $gmatch_caps (param $self (ref $LuaClosure)) (result (ref $CapArr))
    (ref.cast (ref $CapArr) (struct.get $Box $v
      (array.get $UpvalArr (struct.get $LuaClosure $upvals (local.get $self)) (i32.const 4)))))
  ;; A match without captures yields the whole match.
  (func $gmatch_whole (param $sub (ref $LuaArr)) (param $sp i32) (param $end i32) (result anyref)
    (local $whole (ref $LuaArr))
    (local.set $whole (array.new $LuaArr (i32.const 0) (i32.sub (local.get $end) (local.get $sp))))
    (array.copy $LuaArr $LuaArr
      (local.get $whole) (i32.const 0)
      (local.get $sub) (local.get $sp)
      (i32.sub (local.get $end) (local.get $sp)))
    (struct.new $LuaString (local.get $whole) (i32.const 0)))
  ;; The generic entry: every capture.
  (func $builtin_string_gmatch_iter (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $sp i32) (local $end i32) (local $ncaps i32) (local $out (ref $ArgArr)) (local $i i32)
    (call $gmatch_next (local.get $self))
    (local.set $ncaps) (local.set $end) (local.set $sp)
    (if (i32.lt_s (local.get $end) (i32.const 0)) (then (return (global.get $g_empty_args))))
    (if (i32.eqz (local.get $ncaps))
      (then (return (array.new_fixed $ArgArr 1
        (call $gmatch_whole (call $gmatch_subject (local.get $self)) (local.get $sp) (local.get $end))))))
    (local.set $out (array.new $ArgArr (ref.null any) (local.get $ncaps)))
    (block $cdone (loop $cp
      (br_if $cdone (i32.ge_s (local.get $i) (local.get $ncaps)))
      (array.set $ArgArr (local.get $out) (local.get $i)
        (call $cap_to_value (call $gmatch_subject (local.get $self)) (call $gmatch_caps (local.get $self))
                            (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $cp)))
    (local.get $out))
  ;; The fast entry: the first capture (or the whole match) only.
  (func $builtin_string_gmatch_iter_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (local $sp i32) (local $end i32) (local $ncaps i32)
    (call $gmatch_next (local.get $self))
    (local.set $ncaps) (local.set $end) (local.set $sp)
    (if (i32.lt_s (local.get $end) (i32.const 0)) (then (return (ref.null any))))
    (if (i32.eqz (local.get $ncaps))
      (then (return (call $gmatch_whole (call $gmatch_subject (local.get $self)) (local.get $sp) (local.get $end)))))
    (call $cap_to_value (call $gmatch_subject (local.get $self)) (call $gmatch_caps (local.get $self)) (i32.const 0)))

  ;; string.gmatch(s, pat [, init]) — returns an iterator closure with five
  ;; upvalues (s, pat, src, lastmatch, caps). src starts at init-1;
  ;; lastmatch at -1 (no previous match). Generic for drives it to completion.
  (func $builtin_string_gmatch (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $init i32) (local $nargs i32)
    (local.set $nargs (array.len (local.get $args)))
    (local.set $init (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $init (i32.wrap_i64
              (call $as_int_co (call $args_at (local.get $args) (i32.const 2)))))))
    (if (i32.lt_s (local.get $init) (i32.const 1))
      (then (local.set $init (i32.const 1))))
    (array.new_fixed $ArgArr 1
      (struct.new $LuaClosure
        (ref.func $builtin_string_gmatch_iter)
        (array.new_fixed $UpvalArr 5
          (struct.new $Box (call $arg_string (call $args_at (local.get $args) (i32.const 0))))
          (struct.new $Box (call $arg_string (call $args_at (local.get $args) (i32.const 1))))
          (struct.new $Box (call $make_int
            (i64.extend_i32_s (i32.sub (local.get $init) (i32.const 1)))))
          (struct.new $Box (call $make_int (i64.const -1)))
          (struct.new $Box (array.new $CapArr (i32.const 0) (i32.const 64)))) (i32.const 256)
        (ref.func $builtin_string_gmatch_iter_f))))

  ;; --- byte-builder for string.gsub output (step 7) ---
  (func $builder_new (result (ref $Builder))
    (struct.new $Builder
      (array.new $LuaArr (i32.const 0) (i32.const 32))
      (i32.const 0)))

  ;; Ensure $b->arr has at least $need bytes of capacity beyond $b->len.
  (func $builder_reserve (param $b (ref $Builder)) (param $need i32)
    (local $cap i32) (local $new_cap i32) (local $new_arr (ref $LuaArr))
    (local.set $cap (array.len (struct.get $Builder $arr (local.get $b))))
    (if (i32.lt_s
          (i32.sub (local.get $cap) (struct.get $Builder $len (local.get $b)))
          (local.get $need))
      (then
        (local.set $new_cap (i32.mul (local.get $cap) (i32.const 2)))
        (block $ok (loop $grow
          (br_if $ok (i32.ge_s
            (i32.sub (local.get $new_cap)
                     (struct.get $Builder $len (local.get $b)))
            (local.get $need)))
          (local.set $new_cap (i32.mul (local.get $new_cap) (i32.const 2)))
          (br $grow)))
        (local.set $new_arr (array.new $LuaArr (i32.const 0) (local.get $new_cap)))
        (array.copy $LuaArr $LuaArr
          (local.get $new_arr) (i32.const 0)
          (struct.get $Builder $arr (local.get $b)) (i32.const 0)
          (struct.get $Builder $len (local.get $b)))
        (struct.set $Builder $arr (local.get $b) (local.get $new_arr)))))

  (func $builder_append (param $b (ref $Builder)) (param $src (ref $LuaArr))
                        (param $src_start i32) (param $src_len i32)
    (if (i32.le_s (local.get $src_len) (i32.const 0)) (then (return)))
    (call $builder_reserve (local.get $b) (local.get $src_len))
    (array.copy $LuaArr $LuaArr
      (struct.get $Builder $arr (local.get $b))
      (struct.get $Builder $len (local.get $b))
      (local.get $src) (local.get $src_start) (local.get $src_len))
    (struct.set $Builder $len (local.get $b)
      (i32.add (struct.get $Builder $len (local.get $b)) (local.get $src_len))))

  (func $builder_append_byte (param $b (ref $Builder)) (param $byte i32)
    (call $builder_reserve (local.get $b) (i32.const 1))
    (array.set $LuaArr (struct.get $Builder $arr (local.get $b))
      (struct.get $Builder $len (local.get $b)) (local.get $byte))
    (struct.set $Builder $len (local.get $b)
      (i32.add (struct.get $Builder $len (local.get $b)) (i32.const 1))))

  ;; One builder, reused by the library functions that build a result and
  ;; copy it out (string.format, gsub, table.concat), so a call allocates
  ;; only its result rather than a builder and its doublings too.
  ;; $builder_take hands it out empty, or a fresh builder while it is taken
  ;; (a nested call: a __tostring under %s, a gsub callback that formats).
  ;; $builder_give returns the result and puts the builder back
  ;; ($builder_put, for a call that needed no result), unless it grew past
  ;; 64 KB: one huge result shouldn't stay alive in it. A call that
  ;; raises never gives it back; the next one starts a fresh builder.
  (global $g_scratch_bld (mut (ref null $Builder)) (ref.null $Builder))
  (func $builder_take (result (ref $Builder))
    (local $b (ref null $Builder))
    (local.set $b (global.get $g_scratch_bld))
    (if (ref.is_null (local.get $b)) (then (return (call $builder_new))))
    (global.set $g_scratch_bld (ref.null $Builder))
    (struct.set $Builder $len (ref.as_non_null (local.get $b)) (i32.const 0))
    (ref.as_non_null (local.get $b)))
  (func $builder_give (param $b (ref $Builder)) (result (ref $LuaString))
    (call $builder_put (local.get $b))
    (call $builder_finish (local.get $b)))
  (func $builder_put (param $b (ref $Builder))
    (if (i32.le_u (array.len (struct.get $Builder $arr (local.get $b))) (i32.const 65536))
      (then (global.set $g_scratch_bld (local.get $b)))))

  ;; Convert the builder into a (ref $LuaString), trimming to exact length.
  (func $builder_finish (param $b (ref $Builder)) (result (ref $LuaString))
    (local $out (ref $LuaArr)) (local $n i32)
    (local.set $n (struct.get $Builder $len (local.get $b)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (array.copy $LuaArr $LuaArr
      (local.get $out) (i32.const 0)
      (struct.get $Builder $arr (local.get $b)) (i32.const 0)
      (local.get $n))
    (struct.new $LuaString (local.get $out) (i32.const 0)))

  ;; Append capture $idx of the match (sub bytes, ncaps captures) to $b.
  ;; Position captures append their 1-based position as a decimal string.
  ;; Substring captures append their bytes verbatim.
  (func $builder_append_cap
    (param $b (ref $Builder)) (param $sub (ref $LuaArr))
    (param $caps (ref $CapArr)) (param $idx i32)
    (local $start i32) (local $len i32) (local $bytes (ref $LuaArr))
    (local.set $start (array.get $CapArr (local.get $caps)
      (i32.mul (local.get $idx) (i32.const 2))))
    (local.set $len (array.get $CapArr (local.get $caps)
      (i32.add (i32.mul (local.get $idx) (i32.const 2)) (i32.const 1))))
    (if (i32.eq (local.get $len) (i32.const -2))
      (then
        (local.set $bytes (call $int_to_bytes
          (i64.extend_i32_s (i32.add (local.get $start) (i32.const 1)))))
        (call $builder_append (local.get $b) (local.get $bytes)
          (i32.const 0) (array.len (local.get $bytes)))
        (return)))
    (call $builder_append (local.get $b) (local.get $sub)
      (local.get $start) (local.get $len)))

  ;; Expand a string repl into the builder. Treats %0..%9 as backrefs
  ;; (with %0 = whole match), %% = literal '%', other %X = literal X.
  (func $apply_repl_string
    (param $b (ref $Builder))
    (param $repl (ref $LuaArr))
    (param $sub (ref $LuaArr))
    (param $caps (ref $CapArr)) (param $ncaps i32)
    (param $match_start i32) (param $match_end i32)
    (local $n i32) (local $i i32) (local $ch i32) (local $d i32)
    (local $idx i32) (local $start i32) (local $len i32)
    (local.set $n (array.len (local.get $repl)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $ch (array.get_u $LuaArr (local.get $repl) (local.get $i)))
      (if (i32.eq (local.get $ch) (i32.const 37))           ;; '%'
        (then
          (if (i32.ge_s (i32.add (local.get $i) (i32.const 1)) (local.get $n))
            (then (br $done)))
          (local.set $d (array.get_u $LuaArr (local.get $repl)
            (i32.add (local.get $i) (i32.const 1))))
          (if (i32.eq (local.get $d) (i32.const 37))        ;; '%%'
            (then
              (call $builder_append_byte (local.get $b) (i32.const 37))
              (local.set $i (i32.add (local.get $i) (i32.const 2)))
              (br $lp)))
          (if (i32.and (i32.ge_u (local.get $d) (i32.const 48))
                       (i32.le_u (local.get $d) (i32.const 57)))
            (then
              (local.set $idx (i32.sub (local.get $d) (i32.const 48)))
              (if (i32.eqz (local.get $idx))
                (then
                  (call $builder_append (local.get $b) (local.get $sub)
                    (local.get $match_start)
                    (i32.sub (local.get $match_end) (local.get $match_start))))
                (else
                  (if (i32.gt_s (local.get $idx) (local.get $ncaps))
                    (then
                      ;; If pattern has no captures, %1 refers to the whole match.
                      (if (i32.and (i32.eqz (local.get $ncaps))
                                   (i32.eq (local.get $idx) (i32.const 1)))
                        (then (call $builder_append (local.get $b) (local.get $sub)
                                (local.get $match_start)
                                (i32.sub (local.get $match_end) (local.get $match_start))))
                        (else (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 722) (i32.const 25)) (i32.const 0))))))
                    (else
                      (call $builder_append_cap (local.get $b)
                        (local.get $sub) (local.get $caps)
                        (i32.sub (local.get $idx) (i32.const 1)))))))
              (local.set $i (i32.add (local.get $i) (i32.const 2)))
              (br $lp)))
          ;; Other '%X' — append X literally (and drop the '%').
          (call $builder_append_byte (local.get $b) (local.get $d))
          (local.set $i (i32.add (local.get $i) (i32.const 2)))
          (br $lp)))
      (call $builder_append_byte (local.get $b) (local.get $ch))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; Append a replacement-result value to the builder. Supports string,
  ;; number (rendered via tostring), and nil/false (which inserts the
  ;; original match unchanged). Anything else raises.
  (func $append_repl_result
    (param $b (ref $Builder)) (param $v anyref)
    (param $sub (ref $LuaArr))
    (param $match_start i32) (param $match_end i32)
    (local $bytes (ref $LuaArr))
    (if (ref.is_null (local.get $v))
      (then
        (call $builder_append (local.get $b) (local.get $sub)
          (local.get $match_start)
          (i32.sub (local.get $match_end) (local.get $match_start)))
        (return)))
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then
        (if (i32.eqz (struct.get $LuaBool $b
                       (ref.cast (ref $LuaBool) (local.get $v))))
          (then
            (call $builder_append (local.get $b) (local.get $sub)
              (local.get $match_start)
              (i32.sub (local.get $match_end) (local.get $match_start)))
            (return)))
        (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 722) (i32.const 25)) (i32.const 0)))))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then
        (local.set $bytes (call $str_bytes
          (ref.cast (ref $LuaString) (local.get $v))))
        (call $builder_append (local.get $b) (local.get $bytes)
          (i32.const 0) (array.len (local.get $bytes)))
        (return)))
    (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
      (then
        (local.set $bytes (call $str_bytes
          (call $lua_tostring (local.get $v))))
        (call $builder_append (local.get $b) (local.get $bytes)
          (i32.const 0) (array.len (local.get $bytes)))
        (return)))
    (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 722) (i32.const 25)) (i32.const 0))))

  ;; Table repl: $tab[first_capture_or_whole_match] is the replacement.
  (func $apply_repl_table
    (param $b (ref $Builder)) (param $tab (ref $LuaTable))
    (param $sub (ref $LuaArr))
    (param $caps (ref $CapArr)) (param $ncaps i32)
    (param $match_start i32) (param $match_end i32)
    (local $key anyref) (local $bytes (ref $LuaArr))
    (if (i32.eqz (local.get $ncaps))
      (then
        (local.set $bytes (array.new $LuaArr (i32.const 0)
          (i32.sub (local.get $match_end) (local.get $match_start))))
        (array.copy $LuaArr $LuaArr
          (local.get $bytes) (i32.const 0)
          (local.get $sub) (local.get $match_start)
          (i32.sub (local.get $match_end) (local.get $match_start)))
        (local.set $key (struct.new $LuaString (local.get $bytes) (i32.const 0))))
      (else
        (local.set $key (call $cap_to_value
          (local.get $sub) (local.get $caps) (i32.const 0)))))
    (call $append_repl_result
      (local.get $b) (call $tab_get (local.get $tab) (local.get $key))
      (local.get $sub) (local.get $match_start) (local.get $match_end)))

  ;; Function repl: call $fn with captures (or whole match) and use the
  ;; first return value as the replacement.
  (func $apply_repl_function
    (param $b (ref $Builder)) (param $fn (ref $LuaClosure))
    (param $sub (ref $LuaArr))
    (param $caps (ref $CapArr)) (param $ncaps i32)
    (param $match_start i32) (param $match_end i32)
    (local $n i32) (local $i i32)
    (local $args (ref $ArgArr)) (local $bytes (ref $LuaArr))
    (local.set $n (local.get $ncaps))
    (if (i32.eqz (local.get $n)) (then (local.set $n (i32.const 1))))
    (local.set $args (array.new $ArgArr (ref.null any) (local.get $n)))
    (if (i32.eqz (local.get $ncaps))
      (then
        (local.set $bytes (array.new $LuaArr (i32.const 0)
          (i32.sub (local.get $match_end) (local.get $match_start))))
        (array.copy $LuaArr $LuaArr
          (local.get $bytes) (i32.const 0)
          (local.get $sub) (local.get $match_start)
          (i32.sub (local.get $match_end) (local.get $match_start)))
        (array.set $ArgArr (local.get $args) (i32.const 0)
          (struct.new $LuaString (local.get $bytes) (i32.const 0))))
      (else
        (block $cdone (loop $cp
          (br_if $cdone (i32.ge_s (local.get $i) (local.get $ncaps)))
          (array.set $ArgArr (local.get $args) (local.get $i)
            (call $cap_to_value
              (local.get $sub) (local.get $caps) (local.get $i)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $cp)))))
    (call $append_repl_result
      (local.get $b)
      (call $args_first (call $lua_call (local.get $fn) (local.get $args)))
      (local.get $sub) (local.get $match_start) (local.get $match_end)))

  ;; string.gsub(s, pat, repl [, n]). repl is a string, table, or
  ;; function — type dispatched per match.
  (func $builtin_string_gsub (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $sub (ref $LuaArr)) (local $pat (ref $LuaArr))
    (local $repl_v anyref) (local $repl_bytes (ref $LuaArr))
    (local $repl_kind i32)        ;; 0=string, 1=table, 2=function
    (local $n_sub i32) (local $n_pat i32) (local $nargs i32)
    (local $limit i32) (local $count i32) (local $sp i32) (local $end i32)
    (local $ncaps i32) (local $caps (ref $CapArr))
    (local $anchored i32) (local $start_ppos i32)
    (local $last_end i32) (local $b (ref $Builder)) (local $last_match i32)
    (local $subs (ref $LuaString))
    (local.set $subs (call $arg_string (call $args_at (local.get $args) (i32.const 0))))
    (local.set $sub (call $str_bytes (local.get $subs)))
    (local.set $pat (call $str_bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $repl_v (call $args_at (local.get $args) (i32.const 2)))
    ;; Initialize repl_bytes to an empty array so the validator can see
    ;; it's dominated. The classify chain may overwrite it.
    (local.set $repl_bytes (array.new $LuaArr (i32.const 0) (i32.const 0)))
    (local.set $n_sub (array.len (local.get $sub)))
    (local.set $n_pat (array.len (local.get $pat)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $limit (i32.const 2147483647))
    (if (i32.gt_u (local.get $nargs) (i32.const 3))
      (then (local.set $limit (i32.wrap_i64
              (call $as_int_co (call $args_at (local.get $args) (i32.const 3)))))))
    ;; Classify repl. A number coerces to its string form (reference Lua);
    ;; string/table/function as below; anything else errors.
    (if (i32.or (call $is_int (local.get $repl_v))
                (call $is_float (local.get $repl_v)))
      (then (local.set $repl_v (call $lua_tostring (local.get $repl_v)))))
    (if (ref.test (ref $LuaString) (local.get $repl_v))
      (then (local.set $repl_kind (i32.const 0))
            (local.set $repl_bytes (call $str_bytes
              (ref.cast (ref $LuaString) (local.get $repl_v)))))
      (else (if (ref.test (ref $LuaTable) (local.get $repl_v))
        (then (local.set $repl_kind (i32.const 1))
              (local.set $repl_bytes (array.new $LuaArr (i32.const 0) (i32.const 0))))
        (else (if (ref.test (ref $LuaClosure) (local.get $repl_v))
          (then (local.set $repl_kind (i32.const 2))
                (local.set $repl_bytes (array.new $LuaArr (i32.const 0) (i32.const 0))))
          (else (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 722) (i32.const 25)) (i32.const 0)))))))))
    (local.set $start_ppos (call $pat_anchor_start (local.get $pat)))
    (local.set $anchored (local.get $start_ppos))
    (local.set $b (call $builder_take))
    (local.set $caps (array.new $CapArr (i32.const 0) (i32.const 64)))
    ;; End position of the last accepted match. Used to reject an empty match
    ;; sitting exactly where the previous match ended (Lua's `e != lastmatch`),
    ;; which would otherwise double the replacement after a non-empty match.
    (local.set $last_match (i32.const -1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $count) (local.get $limit)))
      (br_if $done (i32.gt_s (local.get $sp) (local.get $n_sub)))
      (call $match_pat
        (local.get $sub) (local.get $sp)
        (local.get $pat) (local.get $start_ppos)
        (local.get $caps) (i32.const 0))
      (local.set $ncaps)
      (local.set $end)
      (if (i32.and (i32.ge_s (local.get $end) (i32.const 0))
                   (i32.eqz (i32.and (i32.eq (local.get $end) (local.get $sp))
                                     (i32.eq (local.get $sp) (local.get $last_match)))))
        (then
          (call $builder_append (local.get $b) (local.get $sub)
            (local.get $last_end)
            (i32.sub (local.get $sp) (local.get $last_end)))
          (if (i32.eq (local.get $repl_kind) (i32.const 0))
            (then (call $apply_repl_string (local.get $b) (local.get $repl_bytes)
                    (local.get $sub) (local.get $caps) (local.get $ncaps)
                    (local.get $sp) (local.get $end))))
          (if (i32.eq (local.get $repl_kind) (i32.const 1))
            (then (call $apply_repl_table (local.get $b)
                    (ref.cast (ref $LuaTable) (local.get $repl_v))
                    (local.get $sub) (local.get $caps) (local.get $ncaps)
                    (local.get $sp) (local.get $end))))
          (if (i32.eq (local.get $repl_kind) (i32.const 2))
            (then (call $apply_repl_function (local.get $b)
                    (ref.cast (ref $LuaClosure) (local.get $repl_v))
                    (local.get $sub) (local.get $caps) (local.get $ncaps)
                    (local.get $sp) (local.get $end))))
          (local.set $count (i32.add (local.get $count) (i32.const 1)))
          (if (i32.eq (local.get $end) (local.get $sp))
            (then
              ;; Empty match: keep the byte at sp verbatim, advance one.
              (if (i32.lt_s (local.get $sp) (local.get $n_sub))
                (then (call $builder_append_byte (local.get $b)
                        (array.get_u $LuaArr (local.get $sub) (local.get $sp)))))
              (local.set $sp (i32.add (local.get $sp) (i32.const 1))))
            (else (local.set $sp (local.get $end))))
          (local.set $last_end (local.get $sp))
          (local.set $last_match (local.get $end))
          (br_if $done (local.get $anchored))
          (br $lp)))
      (br_if $done (local.get $anchored))
      (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
      (br $lp)))
    ;; No match: the subject itself, as reference Lua returns it (the
    ;; builder is still empty).
    (if (i32.eqz (local.get $count))
      (then
        (call $builder_put (local.get $b))
        (return (array.new_fixed $ArgArr 2 (local.get $subs) (ref.i31 (i32.const 0))))))
    (call $builder_append (local.get $b) (local.get $sub)
      (local.get $last_end)
      (i32.sub (local.get $n_sub) (local.get $last_end)))
    (array.new_fixed $ArgArr 2
      (call $builder_give (local.get $b))
      (call $make_int (i64.extend_i32_s (local.get $count)))))
