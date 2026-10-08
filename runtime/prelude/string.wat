;; The string library (except the pattern functions): byte/char/sub and
;; friends, string.format, string.pack / unpack.

;; A builtin's fast entry ($LuaFn1, the `_f` of its name): the arguments
  ;; in registers and the first result returned directly, where $fast_adapter
  ;; would pack an $ArgArr and unpack one (src/builtins.c lists them). Each
  ;; shares its work with the generic entry.

  ;; string.len requires a string (numbers coerce); unlike the `#` operator it
  ;; must reject tables, so use $arg_string rather than $lua_len.
  (func $str_len (param $v anyref) (result anyref)
    (call $make_int (i64.extend_i32_u (array.len (struct.get $LuaString $bytes (call $arg_string (local.get $v)))))))
  (func $builtin_string_len (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $str_len (call $args_at (local.get $args) (i32.const 0)))))
  (func $builtin_string_len_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $str_len (local.get $a0)))

  ;; Lua's string positions (lstrlib.c): $str_start is posrelatI — a start
  ;; position, negative counting from the end, clamped below to 1 — and
  ;; $str_end is getendpos — an end position clamped to 0..$len. Kept in i64,
  ;; so a huge position clamps instead of wrapping.
  (func $str_start (param $pos i64) (param $len i32) (result i64)
    (if (i64.gt_s (local.get $pos) (i64.const 0)) (then (return (local.get $pos))))
    (if (i64.eqz (local.get $pos)) (then (return (i64.const 1))))
    (if (i64.lt_s (local.get $pos) (i64.sub (i64.const 0) (i64.extend_i32_u (local.get $len))))
      (then (return (i64.const 1))))
    (i64.add (i64.add (i64.extend_i32_u (local.get $len)) (local.get $pos)) (i64.const 1)))
  (func $str_end (param $pos i64) (param $len i32) (result i64)
    (if (i64.gt_s (local.get $pos) (i64.extend_i32_u (local.get $len)))
      (then (return (i64.extend_i32_u (local.get $len)))))
    (if (i64.ge_s (local.get $pos) (i64.const 0)) (then (return (local.get $pos))))
    (if (i64.lt_s (local.get $pos) (i64.sub (i64.const 0) (i64.extend_i32_u (local.get $len))))
      (then (return (i64.const 0))))
    (i64.add (i64.add (i64.extend_i32_u (local.get $len)) (local.get $pos)) (i64.const 1)))
  ;; luaL_optinteger: nil (or an absent argument) is the default.
  (func $opt_int (param $v anyref) (param $def i64) (result i64)
    (if (ref.is_null (local.get $v)) (then (return (local.get $def))))
    (call $as_int_co (local.get $v)))

  ;; ASCII-only upper/lower. Shared loop: $delta is +/- 32 and $lo/$hi
  ;; bracket the source-case byte range (inclusive).
  (func $str_case_map
    (param $bytes (ref $LuaArr)) (param $lo i32) (param $hi i32) (param $delta i32)
    (result (ref $LuaArr))
    (local $n i32) (local $i i32) (local $b i32) (local $out (ref $LuaArr))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (array.copy $LuaArr $LuaArr
      (local.get $out)   (i32.const 0)
      (local.get $bytes) (i32.const 0) (local.get $n))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (array.get_u $LuaArr (local.get $out) (local.get $i)))
      (if (i32.and (i32.ge_u (local.get $b) (local.get $lo))
                   (i32.le_u (local.get $b) (local.get $hi)))
        (then (array.set $LuaArr (local.get $out) (local.get $i)
                (i32.add (local.get $b) (local.get $delta)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $out))

;; string.char(...) — builds a string from byte values (each in 0..255).
  ;; Out-of-range values raise.
  (func $char_code (param $v anyref) (result i32)
    (local $b i64)
    (local.set $b (call $as_int_co (local.get $v)))
    (if (i64.gt_u (local.get $b) (i64.const 255))
      (then (call $throw_lit (i32.const 155) (i32.const 18))))   ;; "value out of range"
    (i32.wrap_i64 (local.get $b)))
  (func $builtin_string_char (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $out (ref $LuaArr))
    (local.set $n (array.len (local.get $args)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (array.set $LuaArr (local.get $out) (local.get $i)
        (call $char_code (call $args_at (local.get $args) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out) (i32.const 0))))
  (func $builtin_string_char_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (local $out (ref $LuaArr))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (if (i32.gt_s (local.get $n) (i32.const 0))
      (then (array.set $LuaArr (local.get $out) (i32.const 0) (call $char_code (local.get $a0)))))
    (if (i32.gt_s (local.get $n) (i32.const 1))
      (then (array.set $LuaArr (local.get $out) (i32.const 1) (call $char_code (local.get $a1)))))
    (if (i32.gt_s (local.get $n) (i32.const 2))
      (then (array.set $LuaArr (local.get $out) (i32.const 2) (call $char_code (local.get $a2)))))
    (if (i32.gt_s (local.get $n) (i32.const 3))
      (then (array.set $LuaArr (local.get $out) (i32.const 3) (call $char_code (local.get $a3)))))
    (struct.new $LuaString (local.get $out) (i32.const 0)))

;; string.byte(s [, i [, j]]) — the byte values of s[i..j] as multiple
  ;; results. Defaults: i = 1, j = i. Negative positions count from the end.
  ;; An empty range returns no values. $str_byte_range resolves the range to
  ;; a 0-based first byte and a count (<= 0: none).
  (func $str_byte_range (param $sv anyref) (param $iv anyref) (param $jv anyref)
                        (result (ref $LuaArr) i32 i32)
    (local $bytes (ref $LuaArr)) (local $n i32) (local $pi i64) (local $i i64) (local $j i64)
    (local.set $bytes (struct.get $LuaString $bytes (call $arg_string (local.get $sv))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $pi (call $opt_int (local.get $iv) (i64.const 1)))
    (local.set $j (call $str_end (call $opt_int (local.get $jv) (local.get $pi)) (local.get $n)))
    (local.set $i (call $str_start (local.get $pi) (local.get $n)))
    (if (i64.gt_s (local.get $i) (local.get $j))
      (then (return (local.get $bytes) (i32.const 0) (i32.const 0))))
    (local.get $bytes)
    (i32.wrap_i64 (i64.sub (local.get $i) (i64.const 1)))
    (i32.wrap_i64 (i64.add (i64.sub (local.get $j) (local.get $i)) (i64.const 1))))
  (func $builtin_string_byte (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $first i32) (local $count i32) (local $k i32)
    (local $out (ref $ArgArr))
    (call $str_byte_range (call $args_at (local.get $args) (i32.const 0))
      (call $args_at (local.get $args) (i32.const 1)) (call $args_at (local.get $args) (i32.const 2)))
    (local.set $count) (local.set $first) (local.set $bytes)
    (if (i32.le_s (local.get $count) (i32.const 0)) (then (return (global.get $g_empty_args))))
    (local.set $out (array.new $ArgArr (ref.null any) (local.get $count)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $k) (local.get $count)))
      (array.set $ArgArr (local.get $out) (local.get $k)
        (ref.i31 (array.get_u $LuaArr (local.get $bytes) (i32.add (local.get $first) (local.get $k)))))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $lp)))
    (local.get $out))
  (func $builtin_string_byte_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (local $bytes (ref $LuaArr)) (local $first i32) (local $count i32)
    (call $str_byte_range (local.get $a0) (local.get $a1) (local.get $a2))
    (local.set $count) (local.set $first) (local.set $bytes)
    (if (i32.le_s (local.get $count) (i32.const 0)) (then (return (ref.null any))))
    (ref.i31 (array.get_u $LuaArr (local.get $bytes) (local.get $first))))

;; string.rep(s, n [, sep]) — n copies of s, joined by sep (default "").
  ;; n <= 0 returns "". The result, n*len(s) + max(0, n-1)*len(sep) bytes, is
  ;; allocated once.
  (func $str_rep (param $sv anyref) (param $nv anyref) (param $sepv anyref) (result anyref)
    (local $sb (ref $LuaArr)) (local $pb (ref $LuaArr)) (local $n64 i64) (local $unit i64)
    (local $n i32) (local $slen i32) (local $plen i32)
    (local $total i32) (local $i i32) (local $pos i32)
    (local $out (ref $LuaArr))
    (local.set $sb (struct.get $LuaString $bytes (call $arg_string (local.get $sv))))
    (local.set $n64 (call $as_int_co (local.get $nv)))
    (local.set $pb (array.new $LuaArr (i32.const 0) (i32.const 0)))
    (if (i32.eqz (ref.is_null (local.get $sepv)))
      (then (local.set $pb (struct.get $LuaString $bytes (call $arg_string (local.get $sepv))))))
    (local.set $slen (array.len (local.get $sb)))
    (local.set $plen (array.len (local.get $pb)))
    (if (i64.le_s (local.get $n64) (i64.const 0))
      (then (return (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0)) (i32.const 0)))))
    ;; nothing to repeat: "" for any count, as in lstrlib (no loop)
    (local.set $unit (i64.add (i64.extend_i32_u (local.get $slen)) (i64.extend_i32_u (local.get $plen))))
    (if (i64.eqz (local.get $unit))
      (then (return (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0)) (i32.const 0)))))
    ;; the total, n*unit - len(sep), must fit (also keeps a huge count from wrapping)
    (if (i64.gt_s (local.get $n64)
          (i64.div_u (i64.add (i64.const 0x7fffffff) (i64.extend_i32_u (local.get $plen))) (local.get $unit)))
      (then (call $throw_lit (i32.const 297) (i32.const 9))))   ;; "too large"
    (local.set $n (i32.wrap_i64 (local.get $n64)))
    (local.set $total
      (i32.add
        (i32.mul (local.get $n) (local.get $slen))
        (i32.mul (i32.sub (local.get $n) (i32.const 1)) (local.get $plen))))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $total)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (array.copy $LuaArr $LuaArr
        (local.get $out) (local.get $pos)
        (local.get $sb)  (i32.const 0) (local.get $slen))
      (local.set $pos (i32.add (local.get $pos) (local.get $slen)))
      ;; sep, unless this is the last copy
      (if (i32.and (i32.gt_s (local.get $plen) (i32.const 0))
                   (i32.lt_s (local.get $i) (i32.sub (local.get $n) (i32.const 1))))
        (then
          (array.copy $LuaArr $LuaArr
            (local.get $out) (local.get $pos)
            (local.get $pb)  (i32.const 0) (local.get $plen))
          (local.set $pos (i32.add (local.get $pos) (local.get $plen)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (struct.new $LuaString (local.get $out) (i32.const 0)))
  (func $builtin_string_rep (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $str_rep (call $args_at (local.get $args) (i32.const 0))
      (call $args_at (local.get $args) (i32.const 1)) (call $args_at (local.get $args) (i32.const 2)))))
  (func $builtin_string_rep_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $str_rep (local.get $a0) (local.get $a1) (local.get $a2)))

  ;; string.reverse(s) — byte-reversed string.
  (func $builtin_string_reverse (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $out (ref $LuaArr))
    (local $n i32) (local $i i32)
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (array.set $LuaArr (local.get $out) (local.get $i)
        (array.get_u $LuaArr (local.get $bytes)
          (i32.sub (i32.sub (local.get $n) (i32.const 1)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out) (i32.const 0))))

;; string.upper(s) / string.lower(s) — ASCII only, other bytes unchanged.
  (func $str_upper (param $v anyref) (result anyref)
    (struct.new $LuaString
      (call $str_case_map (struct.get $LuaString $bytes (call $arg_string (local.get $v)))
        (i32.const 97) (i32.const 122) (i32.const -32)) (i32.const 0)))
  (func $str_lower (param $v anyref) (result anyref)
    (struct.new $LuaString
      (call $str_case_map (struct.get $LuaString $bytes (call $arg_string (local.get $v)))
        (i32.const 65) (i32.const 90) (i32.const 32)) (i32.const 0)))
  (func $builtin_string_upper (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $str_upper (call $args_at (local.get $args) (i32.const 0)))))
  (func $builtin_string_upper_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $str_upper (local.get $a0)))
  (func $builtin_string_lower (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $str_lower (call $args_at (local.get $args) (i32.const 0)))))
  (func $builtin_string_lower_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $str_lower (local.get $a0)))

;; string.sub(s, i [, j]): i is required, j defaults to -1.
  (func $str_sub (param $sv anyref) (param $iv anyref) (param $jv anyref) (result anyref)
    (local $bytes (ref $LuaArr)) (local $n i32) (local $i i64) (local $j i64) (local $len i32)
    (local $out (ref $LuaArr))
    (local.set $bytes (struct.get $LuaString $bytes (call $arg_string (local.get $sv))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $i (call $str_start (call $as_int_co (local.get $iv)) (local.get $n)))
    (local.set $j (call $str_end (call $opt_int (local.get $jv) (i64.const -1)) (local.get $n)))
    (if (i64.gt_s (local.get $i) (local.get $j))
      (then (return (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0)) (i32.const 0)))))
    (local.set $len (i32.wrap_i64 (i64.add (i64.sub (local.get $j) (local.get $i)) (i64.const 1))))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $len)))
    (array.copy $LuaArr $LuaArr
      (local.get $out)   (i32.const 0)
      (local.get $bytes) (i32.wrap_i64 (i64.sub (local.get $i) (i64.const 1)))
      (local.get $len))
    (struct.new $LuaString (local.get $out) (i32.const 0)))
  (func $builtin_string_sub (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $str_sub (call $args_at (local.get $args) (i32.const 0))
      (call $args_at (local.get $args) (i32.const 1)) (call $args_at (local.get $args) (i32.const 2)))))
  (func $builtin_string_sub_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $str_sub (local.get $a0) (local.get $a1) (local.get $a2)))

  ;; Builds a $LuaString from the first $n bytes of $fmt_buf.
  (func $fmt_buf_to_str (param $n i32) (result (ref $LuaString))
    (local $out (ref $LuaArr))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)
      (ref.as_non_null (global.get $fmt_buf)) (i32.const 0) (local.get $n))
    (struct.new $LuaString (local.get $out) (i32.const 0)))

  ;; "0x" ++ lowercase hex of $id — the address form string.format("%p") and
  ;; (indirectly) the address-bearing types use.
  (func $ptr_hex (param $id i32) (result (ref $LuaString))
    (ref.cast (ref $LuaString) (call $lua_concat
      (struct.new $LuaString
        (array.new_fixed $LuaArr 2 (i32.const 48) (i32.const 120)) (i32.const 0))   ;; "0x"
      (struct.new $LuaString (call $int_to_hex_bytes (local.get $id)) (i32.const 0)))))

  ;; string.format("%p", v): an address-bearing value (string, table,
  ;; function) formats as "0x<addr>"; everything else (nil, number, boolean)
  ;; is "(null)" — matching reference lua_topointer. Tables use their unique
  ;; struct $id; strings/functions get a stable, distinct host-assigned id.
  (func $fmt_ptr (param $v anyref) (result (ref $LuaString))
    (if (ref.test (ref $LuaTable) (local.get $v))
      (then (return (call $ptr_hex
        (struct.get $LuaTable $id (ref.cast (ref $LuaTable) (local.get $v)))))))
    (if (i32.or (ref.test (ref $LuaString) (local.get $v))
                (ref.test (ref $LuaClosure) (local.get $v)))
      (then (return (call $ptr_hex (call $host_obj_id (local.get $v))))))
    (struct.new $LuaString (array.new_fixed $LuaArr 6
      (i32.const 40) (i32.const 110) (i32.const 117)
      (i32.const 108) (i32.const 108) (i32.const 41)) (i32.const 0)))   ;; "(null)"

  ;; string.format(fmt, ...). Directive parsing and validation (reference
  ;; scanformat/checkformat: per-conversion flag sets, at most two width and
  ;; two precision digits, %q without modifiers, no precision on %c/%p),
  ;; padding, and the integer / char / string / %q conversions all happen
  ;; here; only float rendering (%e %f %g %a and %q of a float) crosses to
  ;; the host through the primitive-only $host_fmt_float. Output accumulates
  ;; in a $Builder. Flag bits: 1 '-', 2 '+', 4 ' ', 8 '#', 16 '0'.
  (func $builtin_string_format (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $fmt (ref $LuaArr)) (local $n i32) (local $i i32) (local $j i32) (local $b i32)
    (local $bld (ref $Builder)) (local $arg_idx i32) (local $arg anyref)
    (local $flags i32) (local $width i32) (local $wnd i32) (local $prec i32) (local $nd i32)
    (local $conv i32) (local $allowed i32) (local $len i32) (local $s (ref $LuaArr)) (local $fx f64)
    (local $written i32) (local $k i32)
    (local.set $fmt (struct.get $LuaString $bytes
      (call $arg_string (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $fmt)))
    (local.set $bld (call $builder_new))
    (local.set $arg_idx (i32.const 1))
    (block $done (loop $main
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $i)))
      (if (i32.ne (local.get $b) (i32.const 37))     ;; literal run up to the next '%'
        (then
          (local.set $j (i32.add (local.get $i) (i32.const 1)))
          (block $rdone (loop $rloop
            (br_if $rdone (i32.ge_s (local.get $j) (local.get $n)))
            (br_if $rdone (i32.eq (array.get_u $LuaArr (local.get $fmt) (local.get $j))
                                   (i32.const 37)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $rloop)))
          (call $builder_append (local.get $bld) (local.get $fmt) (local.get $i)
            (i32.sub (local.get $j) (local.get $i)))
          (local.set $i (local.get $j))
          (br $main)))
      ;; '%' — a trailing lone one is an invalid conversion; "%%" is a literal
      (local.set $j (i32.add (local.get $i) (i32.const 1)))
      (if (i32.ge_s (local.get $j) (local.get $n))
        (then (call $throw_lit (i32.const 416) (i32.const 14))))   ;; "invalid format"
      (if (i32.eq (array.get_u $LuaArr (local.get $fmt) (local.get $j)) (i32.const 37))
        (then
          (call $builder_append_byte (local.get $bld) (i32.const 37))
          (local.set $i (i32.add (local.get $j) (i32.const 1)))
          (br $main)))
      ;; flags
      (local.set $flags (i32.const 0))
      (block $fdone (loop $floop
        (br_if $fdone (i32.ge_s (local.get $j) (local.get $n)))
        (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $j)))
        (if (i32.eq (local.get $b) (i32.const 45))
          (then (local.set $flags (i32.or (local.get $flags) (i32.const 1))))
          (else (if (i32.eq (local.get $b) (i32.const 43))
            (then (local.set $flags (i32.or (local.get $flags) (i32.const 2))))
            (else (if (i32.eq (local.get $b) (i32.const 32))
              (then (local.set $flags (i32.or (local.get $flags) (i32.const 4))))
              (else (if (i32.eq (local.get $b) (i32.const 35))
                (then (local.set $flags (i32.or (local.get $flags) (i32.const 8))))
                (else (if (i32.eq (local.get $b) (i32.const 48))
                  (then (local.set $flags (i32.or (local.get $flags) (i32.const 16))))
                  (else (br $fdone)))))))))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $floop)))
      ;; width: at most two digits
      (local.set $width (i32.const 0))
      (local.set $wnd (i32.const 0))
      (block $wdone (loop $wloop
        (br_if $wdone (i32.ge_s (local.get $j) (local.get $n)))
        (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $j)))
        (br_if $wdone (i32.or (i32.lt_u (local.get $b) (i32.const 48))
                              (i32.gt_u (local.get $b) (i32.const 57))))
        (local.set $width (i32.add (i32.mul (local.get $width) (i32.const 10))
                                   (i32.sub (local.get $b) (i32.const 48))))
        (local.set $wnd (i32.add (local.get $wnd) (i32.const 1)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $wloop)))
      (if (i32.gt_s (local.get $wnd) (i32.const 2))
        (then (call $throw_lit (i32.const 416) (i32.const 14))))
      ;; precision: '.' then at most two digits (none means 0)
      (local.set $prec (i32.const -1))
      (if (i32.and (i32.lt_s (local.get $j) (local.get $n))
                   (i32.eq (array.get_u $LuaArr (local.get $fmt) (local.get $j)) (i32.const 46)))
        (then
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (local.set $prec (i32.const 0))
          (local.set $nd (i32.const 0))
          (block $pdone (loop $ploop
            (br_if $pdone (i32.ge_s (local.get $j) (local.get $n)))
            (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $j)))
            (br_if $pdone (i32.or (i32.lt_u (local.get $b) (i32.const 48))
                                  (i32.gt_u (local.get $b) (i32.const 57))))
            (local.set $prec (i32.add (i32.mul (local.get $prec) (i32.const 10))
                                      (i32.sub (local.get $b) (i32.const 48))))
            (local.set $nd (i32.add (local.get $nd) (i32.const 1)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $ploop)))
          (if (i32.gt_s (local.get $nd) (i32.const 2))
            (then (call $throw_lit (i32.const 416) (i32.const 14))))))
      (if (i32.ge_s (local.get $j) (local.get $n))
        (then (call $throw_lit (i32.const 416) (i32.const 14))))
      (local.set $conv (array.get_u $LuaArr (local.get $fmt) (local.get $j)))
      ;; legality for this conversion
      (local.set $allowed (call $fmt_allowed_flags (local.get $conv)))
      (if (i32.lt_s (local.get $allowed) (i32.const 0))
        (then (call $throw_lit (i32.const 416) (i32.const 14))))
      (if (i32.and (local.get $flags) (i32.xor (local.get $allowed) (i32.const -1)))
        (then (call $throw_lit (i32.const 416) (i32.const 14))))
      (if (i32.eq (local.get $conv) (i32.const 113))            ;; %q: no modifiers at all
        (then (if (i32.or (local.get $wnd) (i32.ge_s (local.get $prec) (i32.const 0)))
          (then (call $throw_lit (i32.const 416) (i32.const 14))))))
      (if (i32.or (i32.eq (local.get $conv) (i32.const 99))     ;; %c / %p: no precision
                  (i32.eq (local.get $conv) (i32.const 112)))
        (then (if (i32.ge_s (local.get $prec) (i32.const 0))
          (then (call $throw_lit (i32.const 416) (i32.const 14))))))
      (local.set $i (i32.add (local.get $j) (i32.const 1)))
      ;; every conversion consumes an argument; running out is an error
      ;; ("bad argument #n ... (no value)"), while an explicit nil is a value
      (if (i32.ge_u (local.get $arg_idx) (array.len (local.get $args)))
        (then (call $throw_lit (i32.const 620) (i32.const 14))))   ;; "value expected"
      (local.set $arg (call $args_at (local.get $args) (local.get $arg_idx)))
      (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
      ;; %p: address form; %c: one byte; %s: tostring (honours __tostring)
      (if (i32.eq (local.get $conv) (i32.const 112))
        (then
          (local.set $s (struct.get $LuaString $bytes (call $fmt_ptr (local.get $arg))))
          (call $fmt_pad_str (local.get $bld) (local.get $s) (array.len (local.get $s))
                             (local.get $flags) (local.get $width))
          (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 99))
        (then
          (local.set $s (array.new $LuaArr
            (i32.wrap_i64 (i64.and (call $as_int_co (local.get $arg)) (i64.const 255)))
            (i32.const 1)))
          (call $fmt_pad_str (local.get $bld) (local.get $s) (i32.const 1)
                             (local.get $flags) (local.get $width))
          (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 115))
        (then
          (local.set $s (struct.get $LuaString $bytes (call $lua_tostring (local.get $arg))))
          (local.set $len (array.len (local.get $s)))
          ;; Plain %s keeps the whole string (embedded NULs ok); with any
          ;; modifier the string must be NUL-free, like Lua.
          (if (i32.or (local.get $flags)
                      (i32.or (local.get $wnd) (i32.ge_s (local.get $prec) (i32.const 0))))
            (then
              (local.set $k (i32.const 0))
              (block $zd (loop $zl
                (br_if $zd (i32.ge_s (local.get $k) (local.get $len)))
                (if (i32.eqz (array.get_u $LuaArr (local.get $s) (local.get $k)))
                  (then (call $throw_lit (i32.const 747) (i32.const 21))))   ;; "string contains zeros"
                (local.set $k (i32.add (local.get $k) (i32.const 1)))
                (br $zl)))
              (if (i32.and (i32.ge_s (local.get $prec) (i32.const 0))
                           (i32.gt_s (local.get $len) (local.get $prec)))
                (then (local.set $len (local.get $prec))))))
          (call $fmt_pad_str (local.get $bld) (local.get $s) (local.get $len)
                             (local.get $flags) (local.get $width))
          (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 113))
        (then (call $fmt_quote (local.get $bld) (local.get $arg)) (br $main)))
      ;; integer conversions
      (if (i32.or (i32.eq (local.get $conv) (i32.const 100)) (i32.eq (local.get $conv) (i32.const 105)))
        (then (call $fmt_int (local.get $bld) (call $as_int_co (local.get $arg)) (i32.const 1)
                (i32.const 10) (i32.const 0) (local.get $flags) (local.get $width) (local.get $prec))
              (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 117))
        (then (call $fmt_int (local.get $bld) (call $as_int_co (local.get $arg)) (i32.const 0)
                (i32.const 10) (i32.const 0) (local.get $flags) (local.get $width) (local.get $prec))
              (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 111))
        (then (call $fmt_int (local.get $bld) (call $as_int_co (local.get $arg)) (i32.const 0)
                (i32.const 8) (i32.const 0) (local.get $flags) (local.get $width) (local.get $prec))
              (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 120))
        (then (call $fmt_int (local.get $bld) (call $as_int_co (local.get $arg)) (i32.const 0)
                (i32.const 16) (i32.const 0) (local.get $flags) (local.get $width) (local.get $prec))
              (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 88))
        (then (call $fmt_int (local.get $bld) (call $as_int_co (local.get $arg)) (i32.const 0)
                (i32.const 16) (i32.const 1) (local.get $flags) (local.get $width) (local.get $prec))
              (br $main)))
      ;; floats (e E f g G a A): %f in wasm when $fmt_fixed can, else (and
      ;; for the rest) rendered and padded by the host
      (local.set $fx (call $as_float_co (local.get $arg)))
      (if (i32.eq (local.get $conv) (i32.const 102))
        (then (if (call $fmt_fixed (local.get $bld) (local.get $fx)
                    (if (result i32) (i32.lt_s (local.get $prec) (i32.const 0)) (then (i32.const 6)) (else (local.get $prec)))
                    (local.get $flags) (local.get $width))
          (then (br $main)))))
      (local.set $written (call $host_fmt_float (local.get $conv) (local.get $flags)
        (local.get $width) (local.get $prec) (local.get $fx)))
      (if (i32.lt_s (local.get $written) (i32.const 0))
        (then (call $throw_lit (i32.const 416) (i32.const 14))))
      (call $builder_append (local.get $bld) (ref.as_non_null (global.get $fmt_buf))
        (i32.const 0) (local.get $written))
      (br $main)))
    (array.new_fixed $ArgArr 1 (call $builder_finish (local.get $bld))))

  ;; Flag set each conversion accepts (reference L_FMTFLAGS{F,X,I,U,C}), or
  ;; -1 for an unknown conversion character.
  (func $fmt_allowed_flags (param $c i32) (result i32)
    (if (i32.or (i32.eq (local.get $c) (i32.const 100)) (i32.eq (local.get $c) (i32.const 105)))
      (then (return (i32.const 23))))                       ;; d i: - + space 0
    (if (i32.eq (local.get $c) (i32.const 117)) (then (return (i32.const 17))))   ;; u: - 0
    (if (i32.or (i32.eq (local.get $c) (i32.const 111))
                (i32.or (i32.eq (local.get $c) (i32.const 120)) (i32.eq (local.get $c) (i32.const 88))))
      (then (return (i32.const 25))))                       ;; o x X: - # 0
    (if (i32.or (i32.eq (local.get $c) (i32.const 99))
                (i32.or (i32.eq (local.get $c) (i32.const 112)) (i32.eq (local.get $c) (i32.const 115))))
      (then (return (i32.const 1))))                        ;; c p s: -
    (if (i32.or (i32.eq (local.get $c) (i32.const 102))
                (i32.or (i32.or (i32.eq (local.get $c) (i32.const 101)) (i32.eq (local.get $c) (i32.const 69)))
                        (i32.or (i32.or (i32.eq (local.get $c) (i32.const 103)) (i32.eq (local.get $c) (i32.const 71)))
                                (i32.or (i32.eq (local.get $c) (i32.const 97)) (i32.eq (local.get $c) (i32.const 65))))))
      (then (return (i32.const 31))))                       ;; f e E g G a A: all (no %F in Lua)
    (if (i32.eq (local.get $c) (i32.const 113)) (then (return (i32.const 0))))    ;; q: none
    (i32.const -1))

  ;; Append $len bytes of $s padded with spaces to $width ('-' pads on the
  ;; right). The %c/%s/%p body writer.
  (func $fmt_pad_str (param $bld (ref $Builder)) (param $s (ref $LuaArr)) (param $len i32)
                     (param $flags i32) (param $width i32)
    (local $pad i32)
    (local.set $pad (i32.sub (local.get $width) (local.get $len)))
    (if (i32.lt_s (local.get $pad) (i32.const 0)) (then (local.set $pad (i32.const 0))))
    (if (i32.eqz (i32.and (local.get $flags) (i32.const 1)))
      (then (call $fmt_fill (local.get $bld) (i32.const 32) (local.get $pad))))
    (call $builder_append (local.get $bld) (local.get $s) (i32.const 0) (local.get $len))
    (if (i32.and (local.get $flags) (i32.const 1))
      (then (call $fmt_fill (local.get $bld) (i32.const 32) (local.get $pad)))))

  (func $fmt_fill (param $bld (ref $Builder)) (param $byte i32) (param $count i32)
    (block $done (loop $lp
      (br_if $done (i32.le_s (local.get $count) (i32.const 0)))
      (call $builder_append_byte (local.get $bld) (local.get $byte))
      (local.set $count (i32.sub (local.get $count) (i32.const 1)))
      (br $lp))))

  ;; C printf integer conversion: $signed selects d/i (else the value is
  ;; taken as unsigned 64-bit, for u/o/x/X), $base 10/8/16, $upper for X.
  ;; Precision is the minimum digit count (0 with a zero value prints
  ;; nothing) and disables the '0' flag; '#' prefixes 0x/0X for non-zero hex
  ;; and forces a leading 0 for octal.
  ;; %.<prec>f of a finite double, exactly, without the host, for the usual
  ;; precisions (0..13). With x = m * 2^e (m < 2^53), x * 10^prec equals
  ;; m * 5^prec * 2^(e+prec); 5^prec < 2^31, so m * 5^prec < 2^84 is exact in
  ;; 128 bits (hi:lo), and one shift with round-half-even on the exact
  ;; remainder gives the correctly rounded digits C's printf prints. Flags and
  ;; width as $fmt_int. Returns 0 having written nothing when the value is
  ;; out of reach (inf/nan, a wider precision, |x| * 10^prec >= 2^64): the
  ;; host renders it.
  (func $fmt_fixed (param $bld (ref $Builder)) (param $x f64) (param $prec i32)
                   (param $flags i32) (param $width i32) (result i32)
    (local $bits i64) (local $neg i32) (local $ex i32) (local $m i64) (local $e i32)
    (local $p5 i64) (local $lo i64) (local $hi i64) (local $t1 i64) (local $t2 i64)
    (local $s i32) (local $t i32) (local $q i64)
    (local $remhi i64) (local $remlo i64) (local $halfhi i64) (local $halflo i64) (local $up i32)
    (local $tmp (ref $LuaArr)) (local $nd i32) (local $signch i32) (local $dot i32)
    (local $body i32) (local $pad i32) (local $i i32)
    (if (i32.gt_u (local.get $prec) (i32.const 13)) (then (return (i32.const 0))))
    (local.set $bits (i64.reinterpret_f64 (local.get $x)))
    (local.set $neg (i64.lt_s (local.get $bits) (i64.const 0)))
    (local.set $ex (i32.wrap_i64 (i64.and (i64.shr_u (local.get $bits) (i64.const 52)) (i64.const 0x7ff))))
    (if (i32.eq (local.get $ex) (i32.const 0x7ff)) (then (return (i32.const 0))))   ;; inf / nan
    (local.set $m (i64.and (local.get $bits) (i64.const 0xfffffffffffff)))
    (if (local.get $ex)
      (then (local.set $m (i64.or (local.get $m) (i64.const 0x10000000000000)))
            (local.set $e (i32.sub (local.get $ex) (i32.const 1075))))
      (else (local.set $e (i32.const -1074))))
    ;; P = m * 5^prec, as hi:lo from two 32x31-bit partial products
    (local.set $p5 (i64.const 1))
    (local.set $i (local.get $prec))
    (block $pd (loop $pl
      (br_if $pd (i32.eqz (local.get $i)))
      (local.set $p5 (i64.mul (local.get $p5) (i64.const 5)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $pl)))
    (local.set $t1 (i64.mul (i64.and (local.get $m) (i64.const 0xffffffff)) (local.get $p5)))
    (local.set $t2 (i64.mul (i64.shr_u (local.get $m) (i64.const 32)) (local.get $p5)))
    (local.set $lo (i64.add (local.get $t1) (i64.shl (local.get $t2) (i64.const 32))))
    (local.set $hi (i64.add (i64.shr_u (local.get $t2) (i64.const 32))
                            (i64.extend_i32_u (i64.lt_u (local.get $lo) (local.get $t1)))))
    ;; q = round(P * 2^s), s = e + prec
    (local.set $s (i32.add (local.get $e) (local.get $prec)))
    (if (i32.ge_s (local.get $s) (i32.const 0))
      (then
        ;; exact left shift; the result must fit 64 bits
        (if (i32.or (i64.ne (local.get $hi) (i64.const 0)) (i32.ge_s (local.get $s) (i32.const 64)))
          (then (return (i32.const 0))))
        (if (i32.gt_s (local.get $s) (i32.const 0))
          (then (if (i64.ne (i64.shr_u (local.get $lo) (i64.extend_i32_u (i32.sub (i32.const 64) (local.get $s))))
                            (i64.const 0))
            (then (return (i32.const 0))))))
        (local.set $q (i64.shl (local.get $lo) (i64.extend_i32_u (local.get $s)))))
      (else
        (local.set $t (i32.sub (i32.const 0) (local.get $s)))
        (if (i32.lt_s (local.get $t) (i32.const 128))
          (then
            (if (i32.lt_s (local.get $t) (i32.const 64))
              (then
                (if (i64.ne (i64.shr_u (local.get $hi) (i64.extend_i32_u (local.get $t))) (i64.const 0))
                  (then (return (i32.const 0))))
                (local.set $q (i64.or (i64.shr_u (local.get $lo) (i64.extend_i32_u (local.get $t)))
                                      (i64.shl (local.get $hi) (i64.extend_i32_u (i32.sub (i32.const 64) (local.get $t))))))
                (local.set $remlo (i64.and (local.get $lo)
                  (i64.sub (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $t))) (i64.const 1))))
                (local.set $halflo (i64.shl (i64.const 1) (i64.extend_i32_u (i32.sub (local.get $t) (i32.const 1))))))
              (else
                (local.set $q (i64.shr_u (local.get $hi) (i64.extend_i32_u (i32.sub (local.get $t) (i32.const 64)))))
                (local.set $remhi (i64.and (local.get $hi)
                  (i64.sub (i64.shl (i64.const 1) (i64.extend_i32_u (i32.sub (local.get $t) (i32.const 64))))
                           (i64.const 1))))
                (local.set $remlo (local.get $lo))
                (if (i32.eq (local.get $t) (i32.const 64))
                  (then (local.set $halflo (i64.const 0x8000000000000000)))
                  (else (local.set $halfhi
                    (i64.shl (i64.const 1) (i64.extend_i32_u (i32.sub (local.get $t) (i32.const 65)))))))))
            ;; round half to even on the exact remainder
            (if (i64.gt_u (local.get $remhi) (local.get $halfhi))
              (then (local.set $up (i32.const 1)))
              (else (if (i64.eq (local.get $remhi) (local.get $halfhi))
                (then (if (i64.gt_u (local.get $remlo) (local.get $halflo))
                  (then (local.set $up (i32.const 1)))
                  (else (if (i64.eq (local.get $remlo) (local.get $halflo))
                    (then (local.set $up (i32.wrap_i64 (i64.and (local.get $q) (i64.const 1))))))))))))
            (if (local.get $up)
              (then
                (local.set $q (i64.add (local.get $q) (i64.const 1)))
                (if (i64.eqz (local.get $q)) (then (return (i32.const 0))))))))))
        ;; (t >= 128: P < 2^84 is below half of 2^t, so q = 0)
    ;; digits of q, least significant first, at least prec + 1 of them
    (local.set $tmp (array.new $LuaArr (i32.const 48) (i32.const 32)))
    (loop $dl
      (array.set $LuaArr (local.get $tmp) (local.get $nd)
        (i32.add (i32.wrap_i64 (i64.rem_u (local.get $q) (i64.const 10))) (i32.const 48)))
      (local.set $q (i64.div_u (local.get $q) (i64.const 10)))
      (local.set $nd (i32.add (local.get $nd) (i32.const 1)))
      (br_if $dl (i64.ne (local.get $q) (i64.const 0))))
    (if (i32.le_s (local.get $nd) (local.get $prec))
      (then (local.set $nd (i32.add (local.get $prec) (i32.const 1)))))
    (local.set $dot (i32.or (i32.gt_s (local.get $prec) (i32.const 0))
                            (i32.ne (i32.and (local.get $flags) (i32.const 8)) (i32.const 0))))
    (local.set $signch (i32.const 0))
    (if (local.get $neg) (then (local.set $signch (i32.const 45)))
      (else (if (i32.and (local.get $flags) (i32.const 2)) (then (local.set $signch (i32.const 43)))
        (else (if (i32.and (local.get $flags) (i32.const 4)) (then (local.set $signch (i32.const 32))))))))
    (local.set $body (i32.add (i32.add (i32.ne (local.get $signch) (i32.const 0)) (local.get $nd))
                              (local.get $dot)))
    (local.set $pad (i32.sub (local.get $width) (local.get $body)))
    (if (i32.lt_s (local.get $pad) (i32.const 0)) (then (local.set $pad (i32.const 0))))
    (if (i32.eqz (i32.and (local.get $flags) (i32.const 17)))   ;; neither '-' nor '0'
      (then (call $fmt_fill (local.get $bld) (i32.const 32) (local.get $pad))))
    (if (local.get $signch) (then (call $builder_append_byte (local.get $bld) (local.get $signch))))
    (if (i32.eq (i32.and (local.get $flags) (i32.const 17)) (i32.const 16))   ;; '0' without '-'
      (then (call $fmt_fill (local.get $bld) (i32.const 48) (local.get $pad))))
    (local.set $i (i32.sub (local.get $nd) (i32.const 1)))
    (block $id (loop $il
      (br_if $id (i32.lt_s (local.get $i) (local.get $prec)))
      (call $builder_append_byte (local.get $bld) (array.get_u $LuaArr (local.get $tmp) (local.get $i)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $il)))
    (if (local.get $dot) (then (call $builder_append_byte (local.get $bld) (i32.const 46))))
    (block $fd (loop $fl
      (br_if $fd (i32.lt_s (local.get $i) (i32.const 0)))
      (call $builder_append_byte (local.get $bld) (array.get_u $LuaArr (local.get $tmp) (local.get $i)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $fl)))
    (if (i32.and (local.get $flags) (i32.const 1))
      (then (call $fmt_fill (local.get $bld) (i32.const 32) (local.get $pad))))
    (i32.const 1))

  (func $fmt_int (param $bld (ref $Builder)) (param $v i64) (param $signed i32)
                 (param $base i32) (param $upper i32)
                 (param $flags i32) (param $width i32) (param $prec i32)
    (local $tmp (ref $LuaArr)) (local $ndig i32) (local $d i32) (local $neg i32)
    (local $zeros i32) (local $signch i32) (local $prefix i32) (local $pad i32) (local $body i32)
    (local $mag i64) (local $i i32) (local $zpad i32)
    (local.set $neg (i32.and (local.get $signed) (i64.lt_s (local.get $v) (i64.const 0))))
    (local.set $mag (if (result i64) (local.get $neg)
      (then (i64.sub (i64.const 0) (local.get $v))) (else (local.get $v))))
    (local.set $tmp (array.new $LuaArr (i32.const 0) (i32.const 24)))
    (if (i32.eqz (i32.and (i32.eqz (local.get $prec)) (i64.eqz (local.get $mag))))
      (then (loop $dl
        (local.set $d (i32.wrap_i64 (i64.rem_u (local.get $mag) (i64.extend_i32_u (local.get $base)))))
        (local.set $mag (i64.div_u (local.get $mag) (i64.extend_i32_u (local.get $base))))
        (array.set $LuaArr (local.get $tmp) (local.get $ndig)
          (if (result i32) (i32.lt_u (local.get $d) (i32.const 10))
            (then (i32.add (local.get $d) (i32.const 48)))
            (else (i32.add (local.get $d) (if (result i32) (local.get $upper)
                                             (then (i32.const 55)) (else (i32.const 87)))))))
        (local.set $ndig (i32.add (local.get $ndig) (i32.const 1)))
        (br_if $dl (i64.ne (local.get $mag) (i64.const 0))))))
    (local.set $zeros (i32.sub (local.get $prec) (local.get $ndig)))
    (if (i32.lt_s (local.get $zeros) (i32.const 0)) (then (local.set $zeros (i32.const 0))))
    (if (i32.and (local.get $flags) (i32.const 8))
      (then
        (if (i32.eq (local.get $base) (i32.const 8))
          (then (if (i32.eqz (local.get $zeros))
            (then
              ;; i32.or is not short-circuiting: guard the array read on $ndig
              (if (if (result i32) (i32.eqz (local.get $ndig))
                    (then (i32.const 1))
                    (else (i32.ne (array.get_u $LuaArr (local.get $tmp)
                                    (i32.sub (local.get $ndig) (i32.const 1)))
                                  (i32.const 48))))
                (then (local.set $zeros (i32.const 1))))))))
        (if (i32.and (i32.eq (local.get $base) (i32.const 16)) (i64.ne (local.get $v) (i64.const 0)))
          (then (local.set $prefix (i32.const 2))))))
    (local.set $signch (i32.const 0))
    (if (local.get $neg) (then (local.set $signch (i32.const 45)))
      (else (if (local.get $signed)
        (then (if (i32.and (local.get $flags) (i32.const 2)) (then (local.set $signch (i32.const 43)))
          (else (if (i32.and (local.get $flags) (i32.const 4)) (then (local.set $signch (i32.const 32))))))))))
    (local.set $body (i32.add (i32.add (i32.ne (local.get $signch) (i32.const 0)) (local.get $prefix))
                              (i32.add (local.get $zeros) (local.get $ndig))))
    (local.set $pad (i32.sub (local.get $width) (local.get $body)))
    (if (i32.lt_s (local.get $pad) (i32.const 0)) (then (local.set $pad (i32.const 0))))
    ;; '0' pads after the sign/prefix, unless '-' or an explicit precision
    (local.set $zpad (i32.and (i32.ne (i32.and (local.get $flags) (i32.const 16)) (i32.const 0))
                              (i32.lt_s (local.get $prec) (i32.const 0))))
    (if (i32.and (i32.eqz (i32.and (local.get $flags) (i32.const 1))) (i32.eqz (local.get $zpad)))
      (then (call $fmt_fill (local.get $bld) (i32.const 32) (local.get $pad))))
    (if (local.get $signch) (then (call $builder_append_byte (local.get $bld) (local.get $signch))))
    (if (local.get $prefix)
      (then (call $builder_append_byte (local.get $bld) (i32.const 48))
            (call $builder_append_byte (local.get $bld)
              (if (result i32) (local.get $upper) (then (i32.const 88)) (else (i32.const 120))))))
    (if (i32.and (i32.eqz (i32.and (local.get $flags) (i32.const 1))) (local.get $zpad))
      (then (call $fmt_fill (local.get $bld) (i32.const 48) (local.get $pad))))
    (call $fmt_fill (local.get $bld) (i32.const 48) (local.get $zeros))
    (local.set $i (i32.sub (local.get $ndig) (i32.const 1)))
    (block $cd (loop $cl
      (br_if $cd (i32.lt_s (local.get $i) (i32.const 0)))
      (call $builder_append_byte (local.get $bld) (array.get_u $LuaArr (local.get $tmp) (local.get $i)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $cl)))
    (if (i32.and (local.get $flags) (i32.const 1))
      (then (call $fmt_fill (local.get $bld) (i32.const 32) (local.get $pad)))))

  ;; %q: a literal that reads back as the same value — nil/true/false, a
  ;; decimal integer (mininteger as hex, which has no decimal literal), a
  ;; hex-float / (0/0) / 1e9999 for floats (host), or a quoted string per
  ;; reference addquoted: " \ and newline get a backslash, other control
  ;; bytes become \ddd (three digits only when a digit follows).
  (func $fmt_quote (param $bld (ref $Builder)) (param $v anyref)
    (local $s (ref $LuaArr)) (local $n i32) (local $i i32) (local $c i32) (local $written i32)
    (local $iv i64)
    (if (ref.is_null (local.get $v))
      (then (call $builder_append (local.get $bld)
              (array.new_data $LuaArr $str_data (i32.const 0) (i32.const 3)) (i32.const 0) (i32.const 3))   ;; "nil"
            (return)))
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then
        (if (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v)))
          (then (call $builder_append (local.get $bld)
                  (array.new_data $LuaArr $str_data (i32.const 3) (i32.const 4)) (i32.const 0) (i32.const 4)))   ;; "true"
          (else (call $builder_append (local.get $bld)
                  (array.new_data $LuaArr $str_data (i32.const 7) (i32.const 5)) (i32.const 0) (i32.const 5))))  ;; "false"
        (return)))
    (if (call $is_int (local.get $v))
      (then
        (local.set $iv (call $as_int (local.get $v)))
        (if (i64.eq (local.get $iv) (i64.const -9223372036854775808))
          (then (call $builder_append (local.get $bld)
            (array.new_fixed $LuaArr 18 (i32.const 48) (i32.const 120) (i32.const 56)
              (i32.const 48) (i32.const 48) (i32.const 48) (i32.const 48) (i32.const 48)
              (i32.const 48) (i32.const 48) (i32.const 48) (i32.const 48) (i32.const 48)
              (i32.const 48) (i32.const 48) (i32.const 48) (i32.const 48) (i32.const 48))
            (i32.const 0) (i32.const 18)))
          (else (call $fmt_int (local.get $bld) (local.get $iv) (i32.const 1) (i32.const 10)
                  (i32.const 0) (i32.const 0) (i32.const 0) (i32.const -1))))
        (return)))
    (if (call $is_float (local.get $v))
      (then
        (local.set $written (call $host_fmt_float (i32.const 113) (i32.const 0) (i32.const 0)
                                                  (i32.const -1) (call $as_float (local.get $v))))
        (call $builder_append (local.get $bld) (ref.as_non_null (global.get $fmt_buf))
          (i32.const 0) (local.get $written))
        (return)))
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $v)))
      (then (call $throw_lit (i32.const 416) (i32.const 14))))   ;; "invalid format"
    (local.set $s (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $v))))
    (local.set $n (array.len (local.get $s)))
    (call $builder_append_byte (local.get $bld) (i32.const 34))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $c (array.get_u $LuaArr (local.get $s) (local.get $i)))
      (if (i32.or (i32.eq (local.get $c) (i32.const 34))
                  (i32.or (i32.eq (local.get $c) (i32.const 92)) (i32.eq (local.get $c) (i32.const 10))))
        (then
          (call $builder_append_byte (local.get $bld) (i32.const 92))
          (call $builder_append_byte (local.get $bld) (local.get $c)))
        (else (if (i32.or (i32.lt_u (local.get $c) (i32.const 32)) (i32.eq (local.get $c) (i32.const 127)))
          (then
            (call $builder_append_byte (local.get $bld) (i32.const 92))
            ;; three digits when a digit follows, else the minimal form (the
            ;; lookahead is guarded: i32.and would read past the end)
            (if (if (result i32) (i32.lt_s (i32.add (local.get $i) (i32.const 1)) (local.get $n))
                  (then (i32.and
                    (i32.ge_u (array.get_u $LuaArr (local.get $s) (i32.add (local.get $i) (i32.const 1))) (i32.const 48))
                    (i32.le_u (array.get_u $LuaArr (local.get $s) (i32.add (local.get $i) (i32.const 1))) (i32.const 57))))
                  (else (i32.const 0)))
              (then
                (call $builder_append_byte (local.get $bld) (i32.add (i32.const 48) (i32.div_u (local.get $c) (i32.const 100))))
                (call $builder_append_byte (local.get $bld) (i32.add (i32.const 48) (i32.rem_u (i32.div_u (local.get $c) (i32.const 10)) (i32.const 10))))
                (call $builder_append_byte (local.get $bld) (i32.add (i32.const 48) (i32.rem_u (local.get $c) (i32.const 10)))))
              (else
                (if (i32.ge_u (local.get $c) (i32.const 100))
                  (then (call $builder_append_byte (local.get $bld) (i32.add (i32.const 48) (i32.div_u (local.get $c) (i32.const 100))))))
                (if (i32.ge_u (local.get $c) (i32.const 10))
                  (then (call $builder_append_byte (local.get $bld) (i32.add (i32.const 48) (i32.rem_u (i32.div_u (local.get $c) (i32.const 10)) (i32.const 10))))))
                (call $builder_append_byte (local.get $bld) (i32.add (i32.const 48) (i32.rem_u (local.get $c) (i32.const 10)))))))
          (else (call $builder_append_byte (local.get $bld) (local.get $c))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $builder_append_byte (local.get $bld) (i32.const 34)))

  ;; --- string.pack / string.unpack / string.packsize helpers ---

  ;; 1 iff $n is a positive power of 2.
  (func $pack_is_pow2 (param $n i32) (result i32)
    (i32.and
      (i32.gt_s (local.get $n) (i32.const 0))
      (i32.eqz (i32.and (local.get $n) (i32.sub (local.get $n) (i32.const 1))))))

  ;; Parse an optional decimal [N] at $bytes[$ppos]. If at least one
  ;; digit is consumed returns that value; otherwise returns $default.
  ;; Returns (value, new_ppos). No range check — caller decides.
  (func $pack_n_suffix
    (param $bytes (ref $LuaArr)) (param $ppos i32) (param $default i32)
    (result i32 i32)
    (local $len i32) (local $c i32) (local $n i32) (local $any i32)
    (local.set $len (array.len (local.get $bytes)))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $ppos) (local.get $len)))
        (local.set $c (array.get_u $LuaArr (local.get $bytes) (local.get $ppos)))
        (br_if $done (i32.lt_u (local.get $c) (i32.const 48)))   ;; '0'
        (br_if $done (i32.gt_u (local.get $c) (i32.const 57)))   ;; '9'
        (local.set $n
          (i32.add (i32.mul (local.get $n) (i32.const 10))
                   (i32.sub (local.get $c) (i32.const 48))))
        (local.set $any (i32.const 1))
        (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
        (br $lp)))
    (if (i32.eqz (local.get $any))
      (then (local.set $n (local.get $default))))
    (local.get $n) (local.get $ppos))

  ;; Compute the byte size of a fixed-size value option letter (b B h H
  ;; i[N] I[N] l L j J T f d n c[N]). Advances ppos past any [N]
  ;; suffix. Returns (size, new_ppos). Raises on:
  ;;   - unknown letter
  ;;   - i[N] / I[N] with N outside [1, 16]
  ;;   - c without [N] (c0 is valid and means zero bytes)
  ;; Caller handles configuration options (< > = ! x X space) and the
  ;; variable-length string options (s z) before invoking this.
  (func $pack_opt_size
    (param $opt i32) (param $bytes (ref $LuaArr)) (param $ppos i32)
    (result i32 i32)
    (local $n i32) (local $newpp i32)
    ;; Fixed-size letters first.
    (if (i32.or (i32.eq (local.get $opt) (i32.const 98))         ;; 'b'
                (i32.eq (local.get $opt) (i32.const 66)))        ;; 'B'
      (then (return (i32.const 1) (local.get $ppos))))
    (if (i32.or (i32.eq (local.get $opt) (i32.const 104))        ;; 'h'
                (i32.eq (local.get $opt) (i32.const 72)))        ;; 'H'
      (then (return (i32.const 2) (local.get $ppos))))
    (if (i32.or (i32.eq (local.get $opt) (i32.const 108))        ;; 'l'
                (i32.eq (local.get $opt) (i32.const 76)))        ;; 'L'
      (then (return (i32.const 8) (local.get $ppos))))
    (if (i32.or (i32.eq (local.get $opt) (i32.const 106))        ;; 'j'
                (i32.eq (local.get $opt) (i32.const 74)))        ;; 'J'
      (then (return (i32.const 8) (local.get $ppos))))
    (if (i32.eq (local.get $opt) (i32.const 84))                 ;; 'T'
      (then (return (i32.const 8) (local.get $ppos))))
    (if (i32.eq (local.get $opt) (i32.const 102))                ;; 'f'
      (then (return (i32.const 4) (local.get $ppos))))
    (if (i32.or (i32.eq (local.get $opt) (i32.const 100))        ;; 'd'
                (i32.eq (local.get $opt) (i32.const 110)))       ;; 'n'
      (then (return (i32.const 8) (local.get $ppos))))
    ;; i / I: optional [N], default 4, range 1..16.
    (if (i32.or (i32.eq (local.get $opt) (i32.const 105))        ;; 'i'
                (i32.eq (local.get $opt) (i32.const 73)))        ;; 'I'
      (then
        (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                             (i32.const 4))
        (local.set $newpp) (local.set $n)
        (if (i32.lt_s (local.get $n) (i32.const 1))
          (then (call $throw_lit (i32.const 355) (i32.const 13))))   ;; "out of limits"
        (if (i32.gt_s (local.get $n) (i32.const 16))
          (then (call $throw_lit (i32.const 355) (i32.const 13))))   ;; "out of limits"
        (return (local.get $n) (local.get $newpp))))
    ;; c: required [N] >= 0. (c0 is allowed and means "zero bytes".)
    (if (i32.eq (local.get $opt) (i32.const 99))                 ;; 'c'
      (then
        (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                             (i32.const -1))
        (local.set $newpp) (local.set $n)
        (if (i32.lt_s (local.get $n) (i32.const 0))
          (then (call $throw_lit (i32.const 368) (i32.const 12))))   ;; "missing size"
        (return (local.get $n) (local.get $newpp))))
    ;; Unknown letter.
    (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 416) (i32.const 14)) (i32.const 0))))

  ;; Add alignment padding so the next $sz-byte write lands at an
  ;; offset that's a multiple of min($sz, $max_align). Raises if that
  ;; stride is not a positive power of 2.
  (func $pack_align
    (param $offset i32) (param $sz i32) (param $max_align i32)
    (result i32)
    (local $stride i32) (local $rem i32)
    (local.set $stride (local.get $sz))
    (if (i32.gt_s (local.get $stride) (local.get $max_align))
      (then (local.set $stride (local.get $max_align))))
    (if (i32.eqz (call $pack_is_pow2 (local.get $stride)))
      (then (call $throw_lit (i32.const 402) (i32.const 14))))   ;; "not power of 2"
    (local.set $rem (i32.rem_u (local.get $offset) (local.get $stride)))
    (if (i32.ne (local.get $rem) (i32.const 0))
      (then (local.set $offset
        (i32.add (local.get $offset)
                 (i32.sub (local.get $stride) (local.get $rem))))))
    (local.get $offset))

  ;; Write the low $n bytes of $val into $buf[$off..$off+n] in the byte
  ;; order selected by $le (1 = little-endian, 0 = big-endian).
  (func $pack_write_int
    (param $buf (ref $LuaArr)) (param $off i32) (param $n i32)
    (param $le i32) (param $val i64)
    (local $i i32) (local $b i32) (local $sign_byte i32)
    ;; For sizes > 8, the bytes past byte 7 carry the sign-extension of
    ;; $val: 0x00 for non-negative, 0xFF for negative. This matches both
    ;; signed pack of a negative i64 (two's-complement extension) and
    ;; unsigned pack (which guarantees $val ≥ 0, so the extension is 0).
    (if (i64.lt_s (local.get $val) (i64.const 0))
      (then (local.set $sign_byte (i32.const 0xff))))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (if (i32.lt_s (local.get $i) (i32.const 8))
        (then (local.set $b (i32.and
                (i32.wrap_i64
                  (i64.shr_u (local.get $val)
                             (i64.extend_i32_u
                               (i32.mul (local.get $i) (i32.const 8)))))
                (i32.const 0xff))))
        (else (local.set $b (local.get $sign_byte))))
      (if (local.get $le)
        (then (array.set $LuaArr (local.get $buf)
                (i32.add (local.get $off) (local.get $i)) (local.get $b)))
        (else (array.set $LuaArr (local.get $buf)
                (i32.add (local.get $off)
                  (i32.sub (i32.sub (local.get $n) (i32.const 1))
                           (local.get $i)))
                (local.get $b))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; Read $n bytes from $buf[$off..$off+n] in the byte order $le and
  ;; return the assembled value zero-extended to i64.
  (func $pack_read_int
    (param $buf (ref $LuaArr)) (param $off i32) (param $n i32)
    (param $le i32) (result i64)
    (local $i i32) (local $val i64) (local $b i32) (local $idx i32)
    ;; Only the first 8 bytes contribute to the assembled i64. Any
    ;; further bytes are sign/zero-extension that the size-vs-fit check
    ;; in the caller ($pack_check_fit / pack_fits_signed/unsigned)
    ;; validates separately. Reading past byte 7 here would `shl` by
    ;; >= 64, whose result is unspecified across wasm engines and was
    ;; ORing the low byte back in on V8.
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (br_if $done (i32.ge_s (local.get $i) (i32.const 8)))
      (if (local.get $le)
        (then (local.set $idx (i32.add (local.get $off) (local.get $i))))
        (else (local.set $idx
                (i32.add (local.get $off)
                  (i32.sub (i32.sub (local.get $n) (i32.const 1))
                           (local.get $i))))))
      (local.set $b (array.get_u $LuaArr (local.get $buf) (local.get $idx)))
      (local.set $val
        (i64.or (local.get $val)
                (i64.shl (i64.extend_i32_u (local.get $b))
                         (i64.extend_i32_u
                           (i32.mul (local.get $i) (i32.const 8))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $val))

  ;; 1 iff $val fits in $n bytes when interpreted as unsigned (top
  ;; (64-8n) bits must be zero). For n=8 always returns 1.
  (func $pack_fits_unsigned (param $val i64) (param $n i32) (result i32)
    (if (result i32) (i32.ge_s (local.get $n) (i32.const 8))
      (then (i32.const 1))
      (else
        (i64.eqz
          (i64.shr_u (local.get $val)
                     (i64.extend_i32_u
                       (i32.mul (local.get $n) (i32.const 8))))))))

  ;; 1 iff $val fits in $n bytes when interpreted as signed two's
  ;; complement, i.e. val ∈ [-(2^(8n-1)), 2^(8n-1)-1]. For n=8 always
  ;; returns 1. Implemented as (val << (64-8n)) >> (64-8n) == val.
  (func $pack_fits_signed (param $val i64) (param $n i32) (result i32)
    (local $shift i64)
    (if (result i32) (i32.ge_s (local.get $n) (i32.const 8))
      (then (i32.const 1))
      (else
        (local.set $shift
          (i64.extend_i32_u
            (i32.mul (i32.sub (i32.const 8) (local.get $n))
                     (i32.const 8))))
        (i64.eq (local.get $val)
                (i64.shr_s (i64.shl (local.get $val) (local.get $shift))
                           (local.get $shift))))))

  ;; Sign-extend the low (8n) bits of $val to a full i64. For n=8 this
  ;; is a no-op.
  (func $pack_signext (param $val i64) (param $n i32) (result i64)
    (local $shift i64)
    (if (result i64) (i32.ge_s (local.get $n) (i32.const 8))
      (then (local.get $val))
      (else
        (local.set $shift
          (i64.extend_i32_u
            (i32.mul (i32.sub (i32.const 8) (local.get $n))
                     (i32.const 8))))
        (i64.shr_s (i64.shl (local.get $val) (local.get $shift))
                   (local.get $shift)))))

  ;; For unpack with $sz > 8 bytes: only the low 8 bytes are assembled
  ;; into $val by $pack_read_int. The remaining (sz-8) bytes must match
  ;; the expected sign-fill so the original number fits in i64:
  ;;   unsigned  → all extras must be 0x00
  ;;   signed    → all extras must equal 0xFF if $val's sign bit is set,
  ;;               else 0x00.
  ;; Throws "data does not fit" on mismatch. No-op when $sz <= 8.
  (func $pack_check_fit
    (param $buf (ref $LuaArr)) (param $off i32) (param $sz i32)
    (param $le i32) (param $is_signed i32) (param $val i64)
    (local $i i32) (local $fill i32) (local $bidx i32) (local $byte i32)
    (if (i32.le_s (local.get $sz) (i32.const 8)) (then (return)))
    (if (i32.and (local.get $is_signed)
                 (i32.wrap_i64
                   (i64.shr_u (local.get $val) (i64.const 63))))
      (then (local.set $fill (i32.const 0xff)))
      (else (local.set $fill (i32.const 0))))
    (local.set $i (i32.const 8))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $sz)))
      (if (local.get $le)
        (then (local.set $bidx (i32.add (local.get $off) (local.get $i))))
        (else (local.set $bidx
                (i32.add (local.get $off)
                  (i32.sub (i32.sub (local.get $sz) (i32.const 1))
                           (local.get $i))))))
      (local.set $byte (array.get_u $LuaArr (local.get $buf) (local.get $bidx)))
      (if (i32.ne (local.get $byte) (local.get $fill))
        (then (call $throw_lit (i32.const 173) (i32.const 17))))   ;; "data does not fit"
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; 1 iff $c is one of the signed integer option letters
  ;; (b, h, i, j, l). All other ints (B H I J L T) are unsigned;
  ;; configurations and non-int options are filtered by the walker
  ;; before we ask this.
  (func $pack_opt_is_signed (param $c i32) (result i32)
    (i32.or
      (i32.or (i32.eq (local.get $c) (i32.const 98))         ;; 'b'
              (i32.eq (local.get $c) (i32.const 104)))       ;; 'h'
      (i32.or
        (i32.or (i32.eq (local.get $c) (i32.const 105))      ;; 'i'
                (i32.eq (local.get $c) (i32.const 106)))     ;; 'j'
        (i32.eq (local.get $c) (i32.const 108)))))           ;; 'l'

  ;; string.packsize(fmt) — returns the byte length that string.pack
  ;; with the same format would produce. Raises if the format contains
  ;; a variable-length option ('s' or 'z'), or any of the per-option
  ;; validation errors raised by helpers above.
  (func $builtin_string_packsize (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr))
    (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $len i32) (local $ppos i32)
    (local $c i32) (local $endian_le i32) (local $max_align i32)
    (local $offset i32) (local $sz i32) (local $n i32) (local $newpp i32)
    (local.set $endian_le (i32.const 1))
    (local.set $max_align (i32.const 1))
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string
        (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $len (array.len (local.get $bytes)))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $ppos) (local.get $len)))
      (local.set $c (array.get_u $LuaArr (local.get $bytes) (local.get $ppos)))
      (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
      ;; Space: ignored.
      (if (i32.eq (local.get $c) (i32.const 32)) (then (br $lp)))
      ;; Endianness flags only change state.
      (if (i32.eq (local.get $c) (i32.const 60))                 ;; '<'
        (then (local.set $endian_le (i32.const 1)) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 62))                 ;; '>'
        (then (local.set $endian_le (i32.const 0)) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 61))                 ;; '='
        (then (local.set $endian_le (i32.const 1)) (br $lp)))
      ;; '!' [N] — set max alignment. Default when no [N] follows is 8
      ;; (native alignment). Range 1..16.
      (if (i32.eq (local.get $c) (i32.const 33))                 ;; '!'
        (then
          (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                               (i32.const 8))
          (local.set $newpp) (local.set $n)
          (if (i32.lt_s (local.get $n) (i32.const 1))
            (then (call $throw_lit (i32.const 355) (i32.const 13))))   ;; "out of limits"
          (if (i32.gt_s (local.get $n) (i32.const 16))
            (then (call $throw_lit (i32.const 355) (i32.const 13))))   ;; "out of limits"
          (local.set $max_align (local.get $n))
          (local.set $ppos (local.get $newpp))
          (br $lp)))
      ;; 'x' — one byte padding, no alignment.
      (if (i32.eq (local.get $c) (i32.const 120))                ;; 'x'
        (then (local.set $offset
                (i32.add (local.get $offset) (i32.const 1)))
              (br $lp)))
      ;; 'X' op — align to op's size, no payload.
      (if (i32.eq (local.get $c) (i32.const 88))                 ;; 'X'
        (then
          (if (i32.ge_u (local.get $ppos) (local.get $len))
            (then (call $throw_lit (i32.const 416) (i32.const 14))))   ;; "invalid format"
          (local.set $c (array.get_u $LuaArr (local.get $bytes)
                                      (local.get $ppos)))
          (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
          (call $pack_opt_size (local.get $c) (local.get $bytes)
                               (local.get $ppos))
          (local.set $newpp) (local.set $sz)
          (local.set $ppos (local.get $newpp))
          (local.set $offset
            (call $pack_align (local.get $offset)
                              (local.get $sz) (local.get $max_align)))
          (br $lp)))
      ;; 's' / 'z' — variable length; rejected in packsize.
      (if (i32.eq (local.get $c) (i32.const 115))                ;; 's'
        (then (call $throw_lit (i32.const 380) (i32.const 22))))   ;; "variable-length format"
      (if (i32.eq (local.get $c) (i32.const 122))                ;; 'z'
        (then (call $throw_lit (i32.const 380) (i32.const 22))))   ;; "variable-length format"
      ;; Any other letter: a fixed-size value option.
      (call $pack_opt_size (local.get $c) (local.get $bytes)
                           (local.get $ppos))
      (local.set $newpp) (local.set $sz)
      (local.set $ppos (local.get $newpp))
      ;; 'c' is not aligned (manual §6.5.2). All other fixed-size
      ;; options are.
      (if (i32.eq (local.get $c) (i32.const 99))                 ;; 'c'
        (then (local.set $offset
                (i32.add (local.get $offset) (local.get $sz))))
        (else
          (local.set $offset
            (call $pack_align (local.get $offset)
                              (local.get $sz) (local.get $max_align)))
          (local.set $offset
            (i32.add (local.get $offset) (local.get $sz)))))
      (br $lp)))
    (array.new_fixed $ArgArr 1
      (call $make_int (i64.extend_i32_s (local.get $offset)))))

  ;; string.pack(fmt, v1, v2, ...) — builds output via $Builder.
  ;; Handles all format options: b/B/h/H/i[N]/I[N]/l/L/j/J/T,
  ;; f/d/n, c[N], z, s[N], x, Xop, < > = endianness, !N alignment.
  (func $builtin_string_pack (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr))
    (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $len i32) (local $ppos i32)
    (local $c i32) (local $endian_le i32) (local $max_align i32)
    (local $sz i32) (local $n i32) (local $newpp i32)
    (local $arg_idx i32) (local $val i64) (local $pad i32)
    (local $b (ref $Builder)) (local $bbuf (ref $LuaArr)) (local $blen i32)
    (local $fval f64)
    (local $str_bytes (ref $LuaArr)) (local $str_len i32)
    (local.set $endian_le (i32.const 1))
    (local.set $max_align (i32.const 1))
    (local.set $arg_idx (i32.const 1))
    (local.set $b (call $builder_new))
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string
        (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $len (array.len (local.get $bytes)))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $ppos) (local.get $len)))
      (local.set $c (array.get_u $LuaArr (local.get $bytes) (local.get $ppos)))
      (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
      (if (i32.eq (local.get $c) (i32.const 32)) (then (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 60))                 ;; '<'
        (then (local.set $endian_le (i32.const 1)) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 62))                 ;; '>'
        (then (local.set $endian_le (i32.const 0)) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 61))                 ;; '='
        (then (local.set $endian_le (i32.const 1)) (br $lp)))
      ;; '!' [N]
      (if (i32.eq (local.get $c) (i32.const 33))                 ;; '!'
        (then
          (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                               (i32.const 8))
          (local.set $newpp) (local.set $n)
          (if (i32.lt_s (local.get $n) (i32.const 1))
            (then (call $throw_lit (i32.const 355) (i32.const 13))))   ;; "out of limits"
          (if (i32.gt_s (local.get $n) (i32.const 16))
            (then (call $throw_lit (i32.const 355) (i32.const 13))))   ;; "out of limits"
          (local.set $max_align (local.get $n))
          (local.set $ppos (local.get $newpp))
          (br $lp)))
      ;; 'x' — one zero byte, no alignment.
      (if (i32.eq (local.get $c) (i32.const 120))                ;; 'x'
        (then (call $builder_append_byte (local.get $b) (i32.const 0))
              (br $lp)))
      ;; 'X' op — align with no payload, no arg consumed.
      (if (i32.eq (local.get $c) (i32.const 88))                 ;; 'X'
        (then
          (if (i32.ge_u (local.get $ppos) (local.get $len))
            (then (call $throw_lit (i32.const 416) (i32.const 14))))   ;; "invalid format"
          (local.set $c (array.get_u $LuaArr (local.get $bytes)
                                      (local.get $ppos)))
          (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
          (call $pack_opt_size (local.get $c) (local.get $bytes)
                               (local.get $ppos))
          (local.set $newpp) (local.set $sz)
          (local.set $ppos (local.get $newpp))
          (local.set $blen (struct.get $Builder $len (local.get $b)))
          (local.set $pad
            (i32.sub
              (call $pack_align (local.get $blen)
                                (local.get $sz) (local.get $max_align))
              (local.get $blen)))
          (block $pad_done (loop $pad_lp
            (br_if $pad_done (i32.le_s (local.get $pad) (i32.const 0)))
            (call $builder_append_byte (local.get $b) (i32.const 0))
            (local.set $pad (i32.sub (local.get $pad) (i32.const 1)))
            (br $pad_lp)))
          (br $lp)))
      ;; 'z' — zero-terminated string. Not aligned. Embedded NULs rejected.
      (if (i32.eq (local.get $c) (i32.const 122))                ;; 'z'
        (then
          (local.set $str_bytes (struct.get $LuaString $bytes
            (ref.cast (ref $LuaString)
              (call $args_at (local.get $args) (local.get $arg_idx)))))
          (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
          (local.set $str_len (array.len (local.get $str_bytes)))
          ;; Scan for embedded NUL.
          (local.set $sz (i32.const 0))
          (block $scan_done (loop $scan_lp
            (br_if $scan_done (i32.ge_s (local.get $sz) (local.get $str_len)))
            (if (i32.eqz (array.get_u $LuaArr (local.get $str_bytes)
                                              (local.get $sz)))
              (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 747) (i32.const 21)) (i32.const 0)))))
            (local.set $sz (i32.add (local.get $sz) (i32.const 1)))
            (br $scan_lp)))
          (call $builder_append (local.get $b) (local.get $str_bytes)
                                (i32.const 0) (local.get $str_len))
          (call $builder_append_byte (local.get $b) (i32.const 0))
          (br $lp)))
      ;; 's' [N] — length-prefixed string. The length prefix is aligned
      ;; like an unsigned int of N bytes; the body is not aligned.
      (if (i32.eq (local.get $c) (i32.const 115))                ;; 's'
        (then
          (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                               (i32.const 8))
          (local.set $newpp) (local.set $n)
          (local.set $ppos (local.get $newpp))
          (if (i32.lt_s (local.get $n) (i32.const 1))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 355) (i32.const 13)) (i32.const 0)))))
          (if (i32.gt_s (local.get $n) (i32.const 16))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 355) (i32.const 13)) (i32.const 0)))))
          (local.set $str_bytes (struct.get $LuaString $bytes
            (ref.cast (ref $LuaString)
              (call $args_at (local.get $args) (local.get $arg_idx)))))
          (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
          (local.set $str_len (array.len (local.get $str_bytes)))
          ;; Length must fit in n bytes unsigned.
          (if (i32.eqz (call $pack_fits_unsigned
                              (i64.extend_i32_u (local.get $str_len))
                              (local.get $n)))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 173) (i32.const 17)) (i32.const 0)))))
          ;; Align builder for the length prefix.
          (local.set $blen (struct.get $Builder $len (local.get $b)))
          (local.set $pad
            (i32.sub
              (call $pack_align (local.get $blen)
                                (local.get $n) (local.get $max_align))
              (local.get $blen)))
          (block $pad_done_s (loop $pad_lp_s
            (br_if $pad_done_s (i32.le_s (local.get $pad) (i32.const 0)))
            (call $builder_append_byte (local.get $b) (i32.const 0))
            (local.set $pad (i32.sub (local.get $pad) (i32.const 1)))
            (br $pad_lp_s)))
          ;; Write length prefix.
          (call $builder_reserve (local.get $b) (local.get $n))
          (local.set $bbuf (struct.get $Builder $arr (local.get $b)))
          (local.set $blen (struct.get $Builder $len (local.get $b)))
          (call $pack_write_int (local.get $bbuf) (local.get $blen)
                                (local.get $n) (local.get $endian_le)
                                (i64.extend_i32_u (local.get $str_len)))
          (struct.set $Builder $len (local.get $b)
            (i32.add (local.get $blen) (local.get $n)))
          ;; Append bytes.
          (call $builder_append (local.get $b) (local.get $str_bytes)
                                (i32.const 0) (local.get $str_len))
          (br $lp)))
      ;; 'c' [N] — fixed-size string. Not aligned (manual §6.5.2).
      (if (i32.eq (local.get $c) (i32.const 99))                 ;; 'c'
        (then
          (call $pack_opt_size (local.get $c) (local.get $bytes)
                               (local.get $ppos))
          (local.set $newpp) (local.set $sz)
          (local.set $ppos (local.get $newpp))
          (local.set $str_bytes (struct.get $LuaString $bytes
            (ref.cast (ref $LuaString)
              (call $args_at (local.get $args) (local.get $arg_idx)))))
          (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
          (local.set $str_len (array.len (local.get $str_bytes)))
          (if (i32.gt_s (local.get $str_len) (local.get $sz))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 173) (i32.const 17)) (i32.const 0)))))
          (call $builder_append (local.get $b) (local.get $str_bytes)
                                (i32.const 0) (local.get $str_len))
          (local.set $pad (i32.sub (local.get $sz) (local.get $str_len)))
          (block $pad_done_c (loop $pad_lp_c
            (br_if $pad_done_c (i32.le_s (local.get $pad) (i32.const 0)))
            (call $builder_append_byte (local.get $b) (i32.const 0))
            (local.set $pad (i32.sub (local.get $pad) (i32.const 1)))
            (br $pad_lp_c)))
          (br $lp)))
      ;; Float options f/d/n. Pack via i32/i64 bit pattern.
      (if (i32.or (i32.eq (local.get $c) (i32.const 102))        ;; 'f'
                  (i32.or (i32.eq (local.get $c) (i32.const 100))   ;; 'd'
                          (i32.eq (local.get $c) (i32.const 110)))) ;; 'n'
        (then
          (if (i32.eq (local.get $c) (i32.const 102))
            (then (local.set $sz (i32.const 4)))
            (else (local.set $sz (i32.const 8))))
          (local.set $blen (struct.get $Builder $len (local.get $b)))
          (local.set $pad
            (i32.sub
              (call $pack_align (local.get $blen)
                                (local.get $sz) (local.get $max_align))
              (local.get $blen)))
          (block $pad_done_f (loop $pad_lp_f
            (br_if $pad_done_f (i32.le_s (local.get $pad) (i32.const 0)))
            (call $builder_append_byte (local.get $b) (i32.const 0))
            (local.set $pad (i32.sub (local.get $pad) (i32.const 1)))
            (br $pad_lp_f)))
          (local.set $fval (call $as_float
            (call $args_at (local.get $args) (local.get $arg_idx))))
          (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
          (if (i32.eq (local.get $sz) (i32.const 4))
            (then (local.set $val
              (i64.extend_i32_u
                (i32.reinterpret_f32 (f32.demote_f64 (local.get $fval))))))
            (else (local.set $val (i64.reinterpret_f64 (local.get $fval)))))
          (call $builder_reserve (local.get $b) (local.get $sz))
          (local.set $bbuf (struct.get $Builder $arr (local.get $b)))
          (local.set $blen (struct.get $Builder $len (local.get $b)))
          (call $pack_write_int (local.get $bbuf) (local.get $blen)
                                (local.get $sz) (local.get $endian_le)
                                (local.get $val))
          (struct.set $Builder $len (local.get $b)
            (i32.add (local.get $blen) (local.get $sz)))
          (br $lp)))
      ;; Integer option (signed or unsigned).
      (call $pack_opt_size (local.get $c) (local.get $bytes)
                           (local.get $ppos))
      (local.set $newpp) (local.set $sz)
      (local.set $ppos (local.get $newpp))
      ;; Align builder.
      (local.set $blen (struct.get $Builder $len (local.get $b)))
      (local.set $pad
        (i32.sub
          (call $pack_align (local.get $blen)
                            (local.get $sz) (local.get $max_align))
          (local.get $blen)))
      (block $pad_done (loop $pad_lp
        (br_if $pad_done (i32.le_s (local.get $pad) (i32.const 0)))
        (call $builder_append_byte (local.get $b) (i32.const 0))
        (local.set $pad (i32.sub (local.get $pad) (i32.const 1)))
        (br $pad_lp)))
      ;; Fetch arg and validate fit (signed vs unsigned per letter).
      (local.set $val (call $as_int_co (call $args_at (local.get $args)
                                                    (local.get $arg_idx))))
      (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
      (if (call $pack_opt_is_signed (local.get $c))
        (then
          (if (i32.eqz (call $pack_fits_signed (local.get $val) (local.get $sz)))
            (then (call $throw_lit (i32.const 173) (i32.const 17)))))     ;; "data does not fit"
        (else
          (if (i32.eqz (call $pack_fits_unsigned (local.get $val) (local.get $sz)))
            (then (call $throw_lit (i32.const 173) (i32.const 17))))))    ;; "data does not fit"
      ;; Write into the builder, then advance its $len.
      (call $builder_reserve (local.get $b) (local.get $sz))
      (local.set $bbuf (struct.get $Builder $arr (local.get $b)))
      (local.set $blen (struct.get $Builder $len (local.get $b)))
      (call $pack_write_int (local.get $bbuf) (local.get $blen)
                            (local.get $sz) (local.get $endian_le)
                            (local.get $val))
      (struct.set $Builder $len (local.get $b)
        (i32.add (local.get $blen) (local.get $sz)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (call $builder_finish (local.get $b))))

  ;; string.unpack(fmt, s [, pos]) — same format coverage as $builtin_string_pack.
  ;; Returns values…, pos (one-past-last-consumed byte, 1-based).
  (func $builtin_string_unpack (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr))
    (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $len i32) (local $ppos i32)
    (local $c i32) (local $endian_le i32) (local $max_align i32)
    (local $sz i32) (local $n i32) (local $newpp i32)
    (local $subj (ref $LuaArr)) (local $subj_len i32) (local $offset i32)
    (local $out (ref $ArgArr)) (local $out_idx i32) (local $nval i32)
    (local $val i64) (local $fval f64)
    (local $str_bytes (ref $LuaArr))
    (local.set $endian_le (i32.const 1))
    (local.set $max_align (i32.const 1))
    (local.set $bytes (struct.get $LuaString $bytes
      (call $arg_string
        (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $len (array.len (local.get $bytes)))
    (local.set $subj (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString)
        (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $subj_len (array.len (local.get $subj)))
    ;; Optional pos: default 1, clamp negatives like string.sub (relative
    ;; to end). For simplicity we accept positive integers >= 1 here.
    (local.set $offset (i32.const 0))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 2))
      (then (local.set $offset
        (i32.sub
          (i32.wrap_i64
            (call $as_int_co (call $args_at (local.get $args) (i32.const 2))))
          (i32.const 1)))))
    ;; Pre-count value-producing options to size the output ArgArr.
    (local.set $nval (call $pack_count_values (local.get $bytes)))
    (local.set $out
      (array.new $ArgArr (ref.null any)
                 (i32.add (local.get $nval) (i32.const 1))))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $ppos) (local.get $len)))
      (local.set $c (array.get_u $LuaArr (local.get $bytes) (local.get $ppos)))
      (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
      (if (i32.eq (local.get $c) (i32.const 32)) (then (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 60))                 ;; '<'
        (then (local.set $endian_le (i32.const 1)) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 62))                 ;; '>'
        (then (local.set $endian_le (i32.const 0)) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 61))                 ;; '='
        (then (local.set $endian_le (i32.const 1)) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 33))                 ;; '!'
        (then
          (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                               (i32.const 8))
          (local.set $newpp) (local.set $n)
          (if (i32.lt_s (local.get $n) (i32.const 1))
            (then (call $throw_lit (i32.const 355) (i32.const 13))))   ;; "out of limits"
          (if (i32.gt_s (local.get $n) (i32.const 16))
            (then (call $throw_lit (i32.const 355) (i32.const 13))))   ;; "out of limits"
          (local.set $max_align (local.get $n))
          (local.set $ppos (local.get $newpp))
          (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 120))                ;; 'x'
        (then (local.set $offset (i32.add (local.get $offset) (i32.const 1)))
              (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 88))                 ;; 'X'
        (then
          (if (i32.ge_u (local.get $ppos) (local.get $len))
            (then (call $throw_lit (i32.const 416) (i32.const 14))))   ;; "invalid format"
          (local.set $c (array.get_u $LuaArr (local.get $bytes)
                                      (local.get $ppos)))
          (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
          (call $pack_opt_size (local.get $c) (local.get $bytes)
                               (local.get $ppos))
          (local.set $newpp) (local.set $sz)
          (local.set $ppos (local.get $newpp))
          (local.set $offset
            (call $pack_align (local.get $offset)
                              (local.get $sz) (local.get $max_align)))
          (br $lp)))
      ;; 'z' — read up to next NUL.
      (if (i32.eq (local.get $c) (i32.const 122))                ;; 'z'
        (then
          (local.set $sz (i32.const 0))
          (block $scan_done_z (loop $scan_lp_z
            (if (i32.ge_u (i32.add (local.get $offset) (local.get $sz))
                          (local.get $subj_len))
              (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 173) (i32.const 17)) (i32.const 0)))))
            (br_if $scan_done_z
              (i32.eqz (array.get_u $LuaArr (local.get $subj)
                         (i32.add (local.get $offset) (local.get $sz)))))
            (local.set $sz (i32.add (local.get $sz) (i32.const 1)))
            (br $scan_lp_z)))
          (local.set $str_bytes
            (array.new $LuaArr (i32.const 0) (local.get $sz)))
          (array.copy $LuaArr $LuaArr
            (local.get $str_bytes) (i32.const 0)
            (local.get $subj) (local.get $offset) (local.get $sz))
          ;; Skip the terminator too.
          (local.set $offset
            (i32.add (i32.add (local.get $offset) (local.get $sz))
                     (i32.const 1)))
          (array.set $ArgArr (local.get $out) (local.get $out_idx)
            (struct.new $LuaString (local.get $str_bytes) (i32.const 0)))
          (local.set $out_idx (i32.add (local.get $out_idx) (i32.const 1)))
          (br $lp)))
      ;; 's' [N] — length prefix then body.
      (if (i32.eq (local.get $c) (i32.const 115))                ;; 's'
        (then
          (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                               (i32.const 8))
          (local.set $newpp) (local.set $n)
          (local.set $ppos (local.get $newpp))
          (if (i32.lt_s (local.get $n) (i32.const 1))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 355) (i32.const 13)) (i32.const 0)))))
          (if (i32.gt_s (local.get $n) (i32.const 16))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 355) (i32.const 13)) (i32.const 0)))))
          (local.set $offset
            (call $pack_align (local.get $offset)
                              (local.get $n) (local.get $max_align)))
          (if (i32.gt_u (i32.add (local.get $offset) (local.get $n))
                        (local.get $subj_len))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 173) (i32.const 17)) (i32.const 0)))))
          (local.set $val (call $pack_read_int (local.get $subj)
                                (local.get $offset) (local.get $n)
                                (local.get $endian_le)))
          (local.set $offset (i32.add (local.get $offset) (local.get $n)))
          (local.set $sz (i32.wrap_i64 (local.get $val)))
          (if (i32.gt_u (i32.add (local.get $offset) (local.get $sz))
                        (local.get $subj_len))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 173) (i32.const 17)) (i32.const 0)))))
          (local.set $str_bytes
            (array.new $LuaArr (i32.const 0) (local.get $sz)))
          (array.copy $LuaArr $LuaArr
            (local.get $str_bytes) (i32.const 0)
            (local.get $subj) (local.get $offset) (local.get $sz))
          (local.set $offset (i32.add (local.get $offset) (local.get $sz)))
          (array.set $ArgArr (local.get $out) (local.get $out_idx)
            (struct.new $LuaString (local.get $str_bytes) (i32.const 0)))
          (local.set $out_idx (i32.add (local.get $out_idx) (i32.const 1)))
          (br $lp)))
      ;; 'c' [N] — fixed-size string, not aligned.
      (if (i32.eq (local.get $c) (i32.const 99))
        (then
          (call $pack_opt_size (local.get $c) (local.get $bytes)
                               (local.get $ppos))
          (local.set $newpp) (local.set $sz)
          (local.set $ppos (local.get $newpp))
          (if (i32.gt_u (i32.add (local.get $offset) (local.get $sz))
                        (local.get $subj_len))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 173) (i32.const 17)) (i32.const 0)))))
          (local.set $str_bytes
            (array.new $LuaArr (i32.const 0) (local.get $sz)))
          (array.copy $LuaArr $LuaArr
            (local.get $str_bytes) (i32.const 0)
            (local.get $subj) (local.get $offset) (local.get $sz))
          (local.set $offset (i32.add (local.get $offset) (local.get $sz)))
          (array.set $ArgArr (local.get $out) (local.get $out_idx)
            (struct.new $LuaString (local.get $str_bytes) (i32.const 0)))
          (local.set $out_idx (i32.add (local.get $out_idx) (i32.const 1)))
          (br $lp)))
      ;; Float read f/d/n.
      (if (i32.or (i32.eq (local.get $c) (i32.const 102))
                  (i32.or (i32.eq (local.get $c) (i32.const 100))
                          (i32.eq (local.get $c) (i32.const 110))))
        (then
          (if (i32.eq (local.get $c) (i32.const 102))
            (then (local.set $sz (i32.const 4)))
            (else (local.set $sz (i32.const 8))))
          (local.set $offset
            (call $pack_align (local.get $offset)
                              (local.get $sz) (local.get $max_align)))
          (if (i32.gt_u (i32.add (local.get $offset) (local.get $sz))
                        (local.get $subj_len))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 173) (i32.const 17)) (i32.const 0)))))
          (local.set $val (call $pack_read_int (local.get $subj)
                                (local.get $offset) (local.get $sz)
                                (local.get $endian_le)))
          (local.set $offset (i32.add (local.get $offset) (local.get $sz)))
          (if (i32.eq (local.get $sz) (i32.const 4))
            (then (local.set $fval (f64.promote_f32
              (f32.reinterpret_i32 (i32.wrap_i64 (local.get $val))))))
            (else (local.set $fval (f64.reinterpret_i64 (local.get $val)))))
          (array.set $ArgArr (local.get $out) (local.get $out_idx)
            (call $make_float (local.get $fval)))
          (local.set $out_idx (i32.add (local.get $out_idx) (i32.const 1)))
          (br $lp)))
      ;; Integer read (signed or unsigned per letter).
      (call $pack_opt_size (local.get $c) (local.get $bytes)
                           (local.get $ppos))
      (local.set $newpp) (local.set $sz)
      (local.set $ppos (local.get $newpp))
      (local.set $offset
        (call $pack_align (local.get $offset)
                          (local.get $sz) (local.get $max_align)))
      (if (i32.gt_u (i32.add (local.get $offset) (local.get $sz))
                    (local.get $subj_len))
        (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 173) (i32.const 17)) (i32.const 0)))))
      (local.set $val (call $pack_read_int (local.get $subj)
                            (local.get $offset) (local.get $sz)
                            (local.get $endian_le)))
      (call $pack_check_fit (local.get $subj) (local.get $offset)
                            (local.get $sz) (local.get $endian_le)
                            (call $pack_opt_is_signed (local.get $c))
                            (local.get $val))
      (if (call $pack_opt_is_signed (local.get $c))
        (then (local.set $val (call $pack_signext (local.get $val) (local.get $sz)))))
      (local.set $offset (i32.add (local.get $offset) (local.get $sz)))
      (array.set $ArgArr (local.get $out) (local.get $out_idx)
        (call $make_int (local.get $val)))
      (local.set $out_idx (i32.add (local.get $out_idx) (i32.const 1)))
      (br $lp)))
    ;; Append final 1-based position.
    (array.set $ArgArr (local.get $out) (local.get $out_idx)
      (call $make_int (i64.extend_i32_s
        (i32.add (local.get $offset) (i32.const 1)))))
    (local.get $out))

  ;; Count value-producing options in a format string (everything but
  ;; configurations, padding, and the sized prefix of Xop). Used by
  ;; unpack to pre-size its $ArgArr. Doesn't validate; the actual walk
  ;; raises on bad input.
  (func $pack_count_values (param $bytes (ref $LuaArr)) (result i32)
    (local $len i32) (local $ppos i32) (local $c i32) (local $n i32)
    (local $newpp i32) (local $count i32)
    (local.set $len (array.len (local.get $bytes)))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $ppos) (local.get $len)))
      (local.set $c (array.get_u $LuaArr (local.get $bytes) (local.get $ppos)))
      (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
      ;; Skip space, < > =.
      (if (i32.or (i32.eq (local.get $c) (i32.const 32))
                  (i32.or (i32.eq (local.get $c) (i32.const 60))
                          (i32.or (i32.eq (local.get $c) (i32.const 62))
                                  (i32.eq (local.get $c) (i32.const 61)))))
        (then (br $lp)))
      ;; ! [N] — consume any digits.
      (if (i32.eq (local.get $c) (i32.const 33))
        (then
          (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                               (i32.const 0))
          (local.set $newpp) (local.set $n)
          (local.set $ppos (local.get $newpp))
          (br $lp)))
      ;; x — padding, no value.
      (if (i32.eq (local.get $c) (i32.const 120)) (then (br $lp)))
      ;; X op[N] — advance past op letter + any digits, no value.
      (if (i32.eq (local.get $c) (i32.const 88))
        (then
          (if (i32.ge_u (local.get $ppos) (local.get $len)) (then (br $lp)))
          (local.set $ppos (i32.add (local.get $ppos) (i32.const 1)))
          (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                               (i32.const 0))
          (local.set $newpp) (local.set $n)
          (local.set $ppos (local.get $newpp))
          (br $lp)))
      ;; Otherwise: a value-producing option (incl. b h i j l B H I J L T
      ;; f d n c s z). Skip any [N] suffix uniformly — over-skip on
      ;; letters that don't take one is harmless since digits don't
      ;; follow them naturally.
      (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                           (i32.const 0))
      (local.set $newpp) (local.set $n)
      (local.set $ppos (local.get $newpp))
      (local.set $count (i32.add (local.get $count) (i32.const 1)))
      (br $lp)))
    (local.get $count))
