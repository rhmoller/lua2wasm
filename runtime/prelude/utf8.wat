;; The utf8 library.

  ;; UTF-8 encoding helper. Writes the UTF-8 encoding of $cp at $out[$pos..]
  ;; and returns the number of bytes written. By default accepts codepoints
  ;; up to 0x10FFFF (real Unicode); with $lax non-zero, accepts up to
  ;; 0x7FFFFFFF using Lua's extended 5- and 6-byte forms. Returns -1 if
  ;; the codepoint is out of range for the chosen mode.
  (func $utf8_encode (param $out (ref $LuaArr)) (param $pos i32)
                     (param $cp i32) (param $lax i32) (result i32)
    (if (i32.lt_s (local.get $cp) (i32.const 0))
      (then (return (i32.const -1))))
    ;; Strict mode rejects beyond the Unicode max; lax allows up to 0x7FFFFFFF
    ;; (encoded with the natural UTF-8 byte-length boundaries below).
    (if (i32.and (i32.eqz (local.get $lax))
                 (i32.gt_u (local.get $cp) (i32.const 0x10FFFF)))
      (then (return (i32.const -1))))
    (if (i32.lt_u (local.get $cp) (i32.const 0x80))
      (then
        (array.set $LuaArr (local.get $out) (local.get $pos) (local.get $cp))
        (return (i32.const 1))))
    (if (i32.lt_u (local.get $cp) (i32.const 0x800))
      (then
        (array.set $LuaArr (local.get $out) (local.get $pos)
          (i32.or (i32.const 0xC0) (i32.shr_u (local.get $cp) (i32.const 6))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 1))
          (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
        (return (i32.const 2))))
    (if (i32.lt_u (local.get $cp) (i32.const 0x10000))
      (then
        (array.set $LuaArr (local.get $out) (local.get $pos)
          (i32.or (i32.const 0xE0) (i32.shr_u (local.get $cp) (i32.const 12))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 1))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 2))
          (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
        (return (i32.const 3))))
    (if (i32.lt_u (local.get $cp) (i32.const 0x200000))
      (then
        (array.set $LuaArr (local.get $out) (local.get $pos)
          (i32.or (i32.const 0xF0) (i32.shr_u (local.get $cp) (i32.const 18))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 1))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 2))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 3))
          (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
        (return (i32.const 4))))
    ;; lax: 5-byte (0x200000..0x3FFFFFF) and 6-byte (0x4000000..0x7FFFFFFF).
    (if (i32.eqz (local.get $lax)) (then (return (i32.const -1))))
    (if (i32.lt_u (local.get $cp) (i32.const 0x4000000))
      (then
        (array.set $LuaArr (local.get $out) (local.get $pos)
          (i32.or (i32.const 0xF8) (i32.shr_u (local.get $cp) (i32.const 24))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 1))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 18))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 2))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 3))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 4))
          (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
        (return (i32.const 5))))
    (if (i32.le_u (local.get $cp) (i32.const 0x7FFFFFFF))
      (then
        (array.set $LuaArr (local.get $out) (local.get $pos)
          (i32.or (i32.const 0xFC) (i32.shr_u (local.get $cp) (i32.const 30))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 1))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 24))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 2))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 18))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 3))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 4))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6))
                                            (i32.const 0x3F))))
        (array.set $LuaArr (local.get $out) (i32.add (local.get $pos) (i32.const 5))
          (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
        (return (i32.const 6))))
    (i32.const -1))

  ;; Step over one UTF-8 codepoint starting at byte $p in array $bytes.
  ;; Returns the byte width of the codepoint (1..6), or 0 if the sequence
  ;; is invalid at $p. With $lax non-zero, accepts 5- and 6-byte lead
  ;; bytes (Lua's extended range up to 0x7FFFFFFF) and skips the
  ;; shortest-encoding check.
  (func $utf8_decode_step (param $bytes (ref $LuaArr)) (param $p i32)
                          (param $lax i32) (result i32)
    (local $b i32) (local $cont i32) (local $n i32) (local $end i32) (local $i i32)
    (local $width i32) (local $cp i32)
    (local.set $n (array.len (local.get $bytes)))
    (if (i32.ge_s (local.get $p) (local.get $n)) (then (return (i32.const 0))))
    (local.set $b (array.get_u $LuaArr (local.get $bytes) (local.get $p)))
    (if (i32.lt_u (local.get $b) (i32.const 0x80)) (then (return (i32.const 1))))
    (if (i32.lt_u (local.get $b) (i32.const 0xC0)) (then (return (i32.const 0))))
    (if (i32.lt_u (local.get $b) (i32.const 0xE0)) (then (local.set $cont (i32.const 1)))
      (else (if (i32.lt_u (local.get $b) (i32.const 0xF0)) (then (local.set $cont (i32.const 2)))
        (else (if (i32.lt_u (local.get $b) (i32.const 0xF8)) (then (local.set $cont (i32.const 3)))
          (else (if (i32.eqz (local.get $lax))
            (then (return (i32.const 0)))
            (else (if (i32.lt_u (local.get $b) (i32.const 0xFC)) (then (local.set $cont (i32.const 4)))
              (else (if (i32.lt_u (local.get $b) (i32.const 0xFE)) (then (local.set $cont (i32.const 5)))
                (else (return (i32.const 0))))))))))))))
    (local.set $end (i32.add (local.get $p) (i32.add (local.get $cont) (i32.const 1))))
    (if (i32.gt_s (local.get $end) (local.get $n)) (then (return (i32.const 0))))
    ;; verify each continuation byte is in 0x80..0xBF
    (local.set $i (i32.add (local.get $p) (i32.const 1)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $end)))
      (local.set $b (array.get_u $LuaArr (local.get $bytes) (local.get $i)))
      (if (i32.or (i32.lt_u (local.get $b) (i32.const 0x80))
                  (i32.ge_u (local.get $b) (i32.const 0xC0)))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.set $width (i32.add (local.get $cont) (i32.const 1)))
    ;; In strict mode (lax=0), also reject codepoints above U+10FFFF and
    ;; UTF-16 surrogates (U+D800..U+DFFF) — both are unassignable in
    ;; valid UTF-8 even though their byte patterns are well-formed.
    (if (i32.eqz (local.get $lax))
      (then
        (local.set $cp (call $utf8_assemble (local.get $bytes) (local.get $p) (local.get $width)))
        (if (i32.gt_u (local.get $cp) (i32.const 0x10FFFF))
          (then (return (i32.const 0))))
        (if (i32.and (i32.ge_u (local.get $cp) (i32.const 0xD800))
                     (i32.le_u (local.get $cp) (i32.const 0xDFFF)))
          (then (return (i32.const 0))))))
    (local.get $width))

  ;; Given a known-valid UTF-8 sequence of $width bytes at position $p,
  ;; assemble and return the codepoint. Width 1..6.
  (func $utf8_assemble (param $bytes (ref $LuaArr)) (param $p i32)
                       (param $width i32) (result i32)
    (local $cp i32) (local $i i32)
    (if (i32.eq (local.get $width) (i32.const 1))
      (then (return (array.get_u $LuaArr (local.get $bytes) (local.get $p)))))
    ;; lead-byte payload mask: first byte holds (7 - width) data bits
    ;; for width 2..6 (5/4/3/2/1/0 bits respectively). 0x7F >> (width-1)
    ;; gives the right mask.
    (local.set $cp (i32.and
      (array.get_u $LuaArr (local.get $bytes) (local.get $p))
      (i32.shr_u (i32.const 0x7F) (i32.sub (local.get $width) (i32.const 1)))))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $width)))
      (local.set $cp (i32.or
        (i32.shl (local.get $cp) (i32.const 6))
        (i32.and (array.get_u $LuaArr (local.get $bytes)
                  (i32.add (local.get $p) (local.get $i)))
                 (i32.const 0x3F))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $cp))

  ;; utf8.codepoint(s [, i [, j [, lax]]]) — codepoints (as multi-return)
  ;; of each character starting in byte range [i, j]. Default j = i.
  ;; Raises on any invalid byte sequence (strict mode is the default).
  (func $builtin_utf8_codepoint (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $n i32) (local $nargs i32)
    (local $i i32) (local $j i32) (local $lax i32)
    (local $posi i64) (local $posj i64)
    (local $p i32) (local $w i32)
    ;; two-pass: first count, then allocate the ArgArr and fill.
    (local $count i32) (local $idx i32)
    (local $out (ref $ArgArr))
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $posi (i64.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $posi (call $as_int_co (call $args_at (local.get $args) (i32.const 1))))))
    (local.set $posi (call $u_posrelat (local.get $posi) (local.get $n)))
    (local.set $posj (local.get $posi))   ;; j defaults to i
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $posj (call $u_posrelat
              (call $as_int_co (call $args_at (local.get $args) (i32.const 2)))
              (local.get $n)))))
    (if (i32.gt_u (local.get $nargs) (i32.const 3))
      (then (local.set $lax (call $lua_truthy
              (call $args_at (local.get $args) (i32.const 3))))))
    ;; Initial position must be >= 1 and final position <= #s ("out of bounds").
    (if (i64.lt_s (local.get $posi) (i64.const 1))
      (then (call $throw_lit (i32.const 846) (i32.const 13))))   ;; "out of bounds"
    (if (i64.gt_s (local.get $posj) (i64.extend_i32_s (local.get $n)))
      (then (call $throw_lit (i32.const 846) (i32.const 13))))   ;; "out of bounds"
    (if (i64.gt_s (local.get $posi) (local.get $posj))
      (then (return (global.get $g_empty_args))))
    (local.set $i (i32.wrap_i64 (local.get $posi)))
    (local.set $j (i32.wrap_i64 (local.get $posj)))
    ;; pass 1: count + validate
    (local.set $p (i32.sub (local.get $i) (i32.const 1)))
    (block $done1 (loop $lp1
      (br_if $done1 (i32.gt_s (i32.add (local.get $p) (i32.const 1)) (local.get $j)))
      (local.set $w (call $utf8_decode_step
        (local.get $bytes) (local.get $p) (local.get $lax)))
      (if (i32.eqz (local.get $w))
        (then (call $throw_lit (i32.const 190) (i32.const 18))))   ;; "invalid UTF-8 code"
      (local.set $p (i32.add (local.get $p) (local.get $w)))
      (local.set $count (i32.add (local.get $count) (i32.const 1)))
      (br $lp1)))
    ;; pass 2: assemble each codepoint into the result array
    (local.set $out (array.new $ArgArr (ref.null any) (local.get $count)))
    (local.set $p (i32.sub (local.get $i) (i32.const 1)))
    (local.set $idx (i32.const 0))
    (block $done2 (loop $lp2
      (br_if $done2 (i32.ge_s (local.get $idx) (local.get $count)))
      (local.set $w (call $utf8_decode_step
        (local.get $bytes) (local.get $p) (local.get $lax)))
      (array.set $ArgArr (local.get $out) (local.get $idx)
        (call $make_int (i64.extend_i32_u
          (call $utf8_assemble (local.get $bytes) (local.get $p) (local.get $w)))))
      (local.set $p (i32.add (local.get $p) (local.get $w)))
      (local.set $idx (i32.add (local.get $idx) (i32.const 1)))
      (br $lp2)))
    (local.get $out))

  ;; True iff byte $b is a UTF-8 continuation byte (0x80..0xBF).
  (func $utf8_iscont (param $b i32) (result i32)
    (i32.eq (i32.and (local.get $b) (i32.const 0xC0)) (i32.const 0x80)))

  ;; utf8.codes iterator. Called with (s, ctrl), where ctrl is the byte
  ;; position the previous step returned (1-based) or 0 to start. Mirrors
  ;; reference iter_aux: read ctrl as an *unsigned* index n; if n >= #s the
  ;; iteration is over (this also handles a negative ctrl, which becomes a
  ;; huge unsigned — so out-of-range positions yield nil instead of an
  ;; out-of-bounds trap). Otherwise skip any continuation bytes, decode the
  ;; codepoint, and reject a stray continuation byte immediately after it
  ;; (strict). Returns empty when past the end. Lax flag ignored.
  (func $builtin_utf8_codes_iter (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $n_bytes i32)
    (local $ctrl i64) (local $n i32) (local $w i32) (local $next i32)
    (local $out (ref $ArgArr))
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n_bytes (array.len (local.get $bytes)))
    (local.set $ctrl (call $as_int_co (call $args_at (local.get $args) (i32.const 1))))
    ;; n = (unsigned)ctrl; n >= #s ends iteration. A negative ctrl is a huge
    ;; unsigned, so it ends too — no out-of-bounds access.
    (if (i32.or (i64.lt_s (local.get $ctrl) (i64.const 0))
                (i64.ge_s (local.get $ctrl)
                          (i64.extend_i32_s (local.get $n_bytes))))
      (then (return (global.get $g_empty_args))))
    (local.set $n (i32.wrap_i64 (local.get $ctrl)))
    ;; Skip continuation bytes to land on the next codepoint's lead byte.
    (block $skipped (loop $sk
      (br_if $skipped (i32.ge_s (local.get $n) (local.get $n_bytes)))
      (br_if $skipped (i32.eqz (call $utf8_iscont
        (array.get_u $LuaArr (local.get $bytes) (local.get $n)))))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $sk)))
    (if (i32.ge_s (local.get $n) (local.get $n_bytes))
      (then (return (global.get $g_empty_args))))
    (local.set $w (call $utf8_decode_step
      (local.get $bytes) (local.get $n) (i32.const 0)))
    (if (i32.eqz (local.get $w))
      (then (call $throw_lit (i32.const 190) (i32.const 18))))   ;; "invalid UTF-8 code"
    ;; A continuation byte right after the codepoint is a malformed sequence.
    (local.set $next (i32.add (local.get $n) (local.get $w)))
    (if (i32.lt_s (local.get $next) (local.get $n_bytes))
      (then (if (call $utf8_iscont
                  (array.get_u $LuaArr (local.get $bytes) (local.get $next)))
        (then (call $throw_lit (i32.const 190) (i32.const 18))))))   ;; "invalid UTF-8 code"
    (local.set $out (array.new $ArgArr (ref.null any) (i32.const 2)))
    (array.set $ArgArr (local.get $out) (i32.const 0)
      (call $make_int (i64.extend_i32_s
        (i32.add (local.get $n) (i32.const 1)))))
    (array.set $ArgArr (local.get $out) (i32.const 1)
      (call $make_int (i64.extend_i32_u
        (call $utf8_assemble (local.get $bytes) (local.get $n) (local.get $w)))))
    (local.get $out))

  ;; utf8.codes(s [, lax]) — returns (iter, s, 0) for generic for.
  ;; Generic for then drives iter(s, prev) until it returns nothing.
  (func $builtin_utf8_codes (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr))
    ;; Reference rejects a string that *starts* with a continuation byte at
    ;; the codes() call (the iterator's skip step would otherwise swallow it).
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 0)))))
    (if (i32.gt_s (array.len (local.get $bytes)) (i32.const 0))
      (then (if (call $utf8_iscont
                  (array.get_u $LuaArr (local.get $bytes) (i32.const 0)))
        (then (call $throw_lit (i32.const 190) (i32.const 18))))))   ;; "invalid UTF-8 code"
    (array.new_fixed $ArgArr 3
      ;; Inline closure for the iter — drops $g_builtin_utf8_codes_iter
      ;; from the live set when utf8.codes is unreferenced.
      (struct.new $LuaClosure
        (ref.func $builtin_utf8_codes_iter) (global.get $g_empty_upvals) (i32.const 256)
        (ref.func $fast_adapter))
      (call $args_at (local.get $args) (i32.const 0))
      (ref.i31 (i32.const 0))))

  ;; Reference u_posrelat: a non-negative position is taken as-is; a negative
  ;; one counts from the end (#s + pos + 1), underflowing to 0 when it would
  ;; go past the start. Shared by utf8.offset/len/codepoint.
  (func $u_posrelat (param $pos i64) (param $len i32) (result i64)
    (if (result i64) (i64.ge_s (local.get $pos) (i64.const 0))
      (then (local.get $pos))
      (else (if (result i64)
              (i64.gt_u (i64.sub (i64.const 0) (local.get $pos))
                        (i64.extend_i32_s (local.get $len)))
        (then (i64.const 0))
        (else (i64.add (i64.add (i64.extend_i32_s (local.get $len)) (local.get $pos))
                       (i64.const 1)))))))

  ;; Build utf8.offset's result: (start, end) 1-based byte positions of the
  ;; codepoint beginning at 0-based $p. For a multi-byte lead byte, $end skips
  ;; to the last continuation byte; for a single byte (or the past-the-end
  ;; position $p == $len) start == end.
  (func $utf8_offset_result (param $bytes (ref $LuaArr)) (param $len i32)
                            (param $p i32) (result (ref $ArgArr))
    (local $e i32)
    (local.set $e (local.get $p))
    (if (i32.lt_s (local.get $p) (local.get $len))
      (then (if (i32.ge_u (array.get_u $LuaArr (local.get $bytes) (local.get $p))
                          (i32.const 0x80))
        (then
          ;; A multi-byte slot that is itself a continuation byte means the
          ;; located position is mid-codepoint (malformed / lone tail).
          (if (call $utf8_iscont (array.get_u $LuaArr (local.get $bytes) (local.get $p)))
            (then (call $throw_lit (i32.const 859) (i32.const 39))))   ;; "initial position is a continuation byte"
          (block $sd (loop $sl
          (br_if $sd (i32.ge_s (i32.add (local.get $e) (i32.const 1)) (local.get $len)))
          (br_if $sd (i32.eqz (call $utf8_iscont
            (array.get_u $LuaArr (local.get $bytes)
              (i32.add (local.get $e) (i32.const 1))))))
          (local.set $e (i32.add (local.get $e) (i32.const 1)))
          (br $sl)))))))
    (array.new_fixed $ArgArr 2
      (call $make_int (i64.extend_i32_s (i32.add (local.get $p) (i32.const 1))))
      (call $make_int (i64.extend_i32_s (i32.add (local.get $e) (i32.const 1))))))

  ;; utf8.offset(s, n [, i]) — locate the n-th codepoint relative to byte i.
  ;; Returns its start AND end byte positions (Lua 5.5), or nil if not found.
  ;; Default i = 1 (n >= 0) or #s+1 (n < 0). n == 0 finds the start of the
  ;; codepoint containing byte i. Faithful port of reference byteoffset:
  ;; a position outside [1, #s+1] errors "position out of bounds"; a non-zero
  ;; n starting on a continuation byte errors. The while-loops guard $len
  ;; explicitly (no C null terminator to stop on).
  (func $builtin_utf8_offset (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $len i32) (local $nargs i32)
    (local $n i64) (local $posi i64) (local $p i32)
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $len (array.len (local.get $bytes)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $n (call $as_int_co (call $args_at (local.get $args) (i32.const 1))))
    ;; default 1-based posi: 1 if n >= 0, else #s+1
    (if (i64.ge_s (local.get $n) (i64.const 0))
      (then (local.set $posi (i64.const 1)))
      (else (local.set $posi
        (i64.add (i64.extend_i32_s (local.get $len)) (i64.const 1)))))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $posi (call $u_posrelat
              (call $as_int_co (call $args_at (local.get $args) (i32.const 2)))
              (local.get $len)))))
    ;; posi must be in [1, #s+1]
    (if (i32.eqz (i32.and
          (i64.ge_s (local.get $posi) (i64.const 1))
          (i64.le_s (i64.sub (local.get $posi) (i64.const 1))
                    (i64.extend_i32_s (local.get $len)))))
      (then (call $throw_lit (i32.const 837) (i32.const 22))))   ;; "position out of bounds"
    (local.set $p (i32.wrap_i64 (i64.sub (local.get $posi) (i64.const 1))))  ;; 0-based

    ;; n == 0: walk back to the start of the codepoint containing byte $p.
    (if (i64.eqz (local.get $n))
      (then
        (block $z (loop $zl
          (br_if $z (i32.le_s (local.get $p) (i32.const 0)))
          (br_if $z (i32.ge_s (local.get $p) (local.get $len)))
          (br_if $z (i32.eqz (call $utf8_iscont
            (array.get_u $LuaArr (local.get $bytes) (local.get $p)))))
          (local.set $p (i32.sub (local.get $p) (i32.const 1)))
          (br $zl)))
        (return (call $utf8_offset_result
          (local.get $bytes) (local.get $len) (local.get $p)))))

    ;; n != 0: the start position must not be a continuation byte.
    (if (i32.lt_s (local.get $p) (local.get $len))
      (then (if (call $utf8_iscont
                  (array.get_u $LuaArr (local.get $bytes) (local.get $p)))
        (then (call $throw_lit (i32.const 859) (i32.const 39))))))   ;; "initial position is a continuation byte"

    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then
        ;; move back: while (n<0 && p>0) { p--; skip continuation; n++ }
        (block $bk (loop $bkl
          (br_if $bk (i32.eqz (i32.and (i64.lt_s (local.get $n) (i64.const 0))
                                       (i32.gt_s (local.get $p) (i32.const 0)))))
          (local.set $p (i32.sub (local.get $p) (i32.const 1)))
          (block $ld (loop $ldl
            (br_if $ld (i32.le_s (local.get $p) (i32.const 0)))
            (br_if $ld (i32.eqz (call $utf8_iscont
              (array.get_u $LuaArr (local.get $bytes) (local.get $p)))))
            (local.set $p (i32.sub (local.get $p) (i32.const 1)))
            (br $ldl)))
          (local.set $n (i64.add (local.get $n) (i64.const 1)))
          (br $bkl))))
      (else
        ;; move forward: n--; while (n>0 && p<len) { p++; skip continuation; n-- }
        (local.set $n (i64.sub (local.get $n) (i64.const 1)))
        (block $fw (loop $fwl
          (br_if $fw (i32.eqz (i32.and (i64.gt_s (local.get $n) (i64.const 0))
                                       (i32.lt_s (local.get $p) (local.get $len)))))
          (local.set $p (i32.add (local.get $p) (i32.const 1)))
          (block $fd (loop $fdl
            (br_if $fd (i32.ge_s (local.get $p) (local.get $len)))
            (br_if $fd (i32.eqz (call $utf8_iscont
              (array.get_u $LuaArr (local.get $bytes) (local.get $p)))))
            (local.set $p (i32.add (local.get $p) (i32.const 1)))
            (br $fdl)))
          (local.set $n (i64.sub (local.get $n) (i64.const 1)))
          (br $fwl)))))

    ;; n must be exactly consumed; otherwise the codepoint was not found.
    (if (i64.ne (local.get $n) (i64.const 0))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (call $utf8_offset_result (local.get $bytes) (local.get $len) (local.get $p)))

  ;; utf8.len(s [, i [, j [, lax]]]) — count codepoints starting in [i, j].
  ;; Returns the count, OR (nil, errpos) on the first invalid byte.
  (func $builtin_utf8_len (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $n i32) (local $nargs i32)
    (local $posi i64) (local $posj i64) (local $lax i32)
    (local $p i32) (local $end i32) (local $w i32) (local $count i64)
    (local $out (ref $ArgArr))
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $posi (i64.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $posi (call $as_int_co (call $args_at (local.get $args) (i32.const 1))))))
    (local.set $posi (call $u_posrelat (local.get $posi) (local.get $n)))
    (local.set $posj (i64.const -1))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $posj (call $as_int_co (call $args_at (local.get $args) (i32.const 2))))))
    (local.set $posj (call $u_posrelat (local.get $posj) (local.get $n)))
    (if (i32.gt_u (local.get $nargs) (i32.const 3))
      (then (local.set $lax (call $lua_truthy
              (call $args_at (local.get $args) (i32.const 3))))))
    ;; Initial position must be in [1, #s+1]; final position must be <= #s.
    (if (i32.eqz (i32.and (i64.ge_s (local.get $posi) (i64.const 1))
                          (i64.le_s (i64.sub (local.get $posi) (i64.const 1))
                                    (i64.extend_i32_s (local.get $n)))))
      (then (call $throw_lit (i32.const 846) (i32.const 13))))   ;; "out of bounds"
    (if (i32.eqz (i64.lt_s (i64.sub (local.get $posj) (i64.const 1))
                           (i64.extend_i32_s (local.get $n))))
      (then (call $throw_lit (i32.const 846) (i32.const 13))))   ;; "out of bounds"
    (local.set $p (i32.wrap_i64 (i64.sub (local.get $posi) (i64.const 1))))    ;; 0-based start
    (local.set $end (i32.wrap_i64 (i64.sub (local.get $posj) (i64.const 1))))  ;; 0-based last
    (block $done (loop $lp
      (br_if $done (i32.gt_s (local.get $p) (local.get $end)))
      (local.set $w (call $utf8_decode_step
        (local.get $bytes) (local.get $p) (local.get $lax)))
      (if (i32.eqz (local.get $w))
        (then
          ;; invalid sequence: return (nil, 1-based position of bad byte)
          (local.set $out (array.new $ArgArr (ref.null any) (i32.const 2)))
          (array.set $ArgArr (local.get $out) (i32.const 0) (ref.null any))
          (array.set $ArgArr (local.get $out) (i32.const 1)
            (call $make_int (i64.extend_i32_s
              (i32.add (local.get $p) (i32.const 1)))))
          (return (local.get $out))))
      (local.set $p (i32.add (local.get $p) (local.get $w)))
      (local.set $count (i64.add (local.get $count) (i64.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (call $make_int (local.get $count))))

  ;; utf8.char(...) — encode each integer codepoint, concatenated.
  ;; Strict mode (Lua's default for utf8.char): codepoints must be valid
  ;; Unicode (0..0x10FFFF). We do a worst-case 4-byte pre-allocate, encode,
  ;; then if the total comes up short, shrink via array.copy.
  (func $builtin_utf8_char (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $cp i64) (local $w i32) (local $pos i32)
    (local $buf (ref $LuaArr)) (local $out (ref $LuaArr))
    (local.set $n (array.len (local.get $args)))
    ;; Worst case is 6 bytes per codepoint (lax encoding up to 0x7FFFFFFF).
    (local.set $buf (array.new $LuaArr (i32.const 0)
                      (i32.mul (local.get $n) (i32.const 6))))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $cp (call $as_int_co (call $args_at (local.get $args) (local.get $i))))
      ;; reference accepts 0..MAXUTF (0x7FFFFFFF), encoding >U+10FFFF as
      ;; extended (5/6-byte) UTF-8; reject out of range before truncating.
      (if (i32.or (i64.lt_s (local.get $cp) (i64.const 0))
                  (i64.gt_s (local.get $cp) (i64.const 0x7FFFFFFF)))
        (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 155) (i32.const 18)) (i32.const 0)))))
      (local.set $w (call $utf8_encode
        (local.get $buf) (local.get $pos)
        (i32.wrap_i64 (local.get $cp)) (i32.const 1)))
      (if (i32.lt_s (local.get $w) (i32.const 0))
        (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 155) (i32.const 18)) (i32.const 0)))))
      (local.set $pos (i32.add (local.get $pos) (local.get $w)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    ;; trim to actual length
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $pos)))
    (array.copy $LuaArr $LuaArr
      (local.get $out) (i32.const 0)
      (local.get $buf) (i32.const 0) (local.get $pos))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out) (i32.const 0))))
