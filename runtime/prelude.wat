;; Auto-extracted from codegen.c. Edit here; codegen.c #embeds it.
  ;; --- value-rep types ---
  (type $LuaArr    (array (mut i8)))
  (type $LuaString (sub (struct (field $bytes (ref $LuaArr)))))
  (type $LuaFloat  (sub (struct (field $v f64))))
  (type $LuaInt    (sub (struct (field $v i64))))
  (type $LuaBool   (sub (struct (field $b i32))))
  ;; --- closure / function types (mutually recursive) ---
  (type $Box       (sub (struct (field $v (mut anyref)))))
  (type $ArgArr    (array (mut anyref)))
  (type $UpvalArr  (array (mut (ref $Box))))
  ;; Capture buffer for Lua patterns. Two i32 cells per capture:
  ;;   [2*i]   = subject byte offset where capture i starts
  ;;   [2*i+1] = length sentinel:
  ;;               >= 0  closed substring capture, that many bytes
  ;;               -1    open substring capture (still on the parser stack)
  ;;               -2    position capture (cell [2*i] is the 0-based pos)
  (type $CapArr    (array (mut i32)))
  ;; Growable byte buffer used by string.gsub. Owns a backing $LuaArr
  ;; that doubles on overflow.
  (type $Builder   (struct (field $arr (mut (ref $LuaArr)))
                           (field $len (mut i32))))
  (rec
    (type $LuaClosure (sub (struct (field $code (ref $LuaFn))
                                   (field $upvals (ref $UpvalArr)))))
    (type $LuaFn (func (param (ref $LuaClosure))
                       (param (ref $ArgArr))
                       (result (ref $ArgArr)))))
  ;; --- table type ---
  ;; The table keeps an insertion-ordered dense pair of arrays (keys/vals)
  ;; so iteration stays simple and `next` is well-defined. Lookups go
  ;; through an open-addressing hash index $idx, which stores
  ;; (entry_position + 1) for each populated slot; 0 means empty. The
  ;; index is power-of-two sized and probed linearly (the simple variant
  ;; of robin-hood; we don't displace, but the load factor cap keeps
  ;; chains short).
  (type $TArr (array (mut anyref)))
  (type $IArr (array (mut i32)))
  (rec
    (type $LuaTable (sub (struct
      (field $keys (mut (ref null $TArr)))
      (field $vals (mut (ref null $TArr)))
      (field $n    (mut i32))
      (field $cap  (mut i32))
      (field $idx  (mut (ref null $IArr)))
      (field $mask (mut i32))
      (field $meta (mut (ref null $LuaTable)))))))

  (import "host" "print" (func $host_print (param anyref)))
  (import "host" "write_raw" (func $host_write_raw (param anyref)))
  (import "host" "warn"  (func $host_warn  (param anyref)))
  ;; host_fmt: format one value into the shared $fmt_buf scratch array.
  ;;   kind: 0 = %d (i_val)   1 = unused (s handled wasm-side)
  ;;         2 = %g (f_val + prec)   3 = %f   4 = %e   5 = %x (i_val)
  ;; Returns the number of bytes written.
  (import "host" "fmt" (func $host_fmt (param i32) (param i64) (param f64) (param i32) (result i32)))
  ;; host_math: dispatch transcendental functions to the JS Math API.
  ;;   0 sin  1 cos  2 tan  3 asin  4 acos  5 atan  6 exp  7 log
  (import "host" "math" (func $host_math (param i32) (param f64) (result f64)))
  ;; host_math2: two-arg math fns.
  ;;   0 atan2(y, x)   1 pow(base, exp)
  (import "host" "math2" (func $host_math2 (param i32) (param f64) (param f64) (result f64)))
  ;; host_read: read from stdin in one of several modes into $fmt_buf.
  ;;   mode 0  -> "l" (line, no \n)
  ;;   mode 1  -> "L" (line, with \n)
  ;;   mode 2  -> "a" (read all remaining)
  ;;   mode 3  -> count: exactly $count bytes (or fewer if EOF)
  ;; Returns the number of bytes written, or -1 on EOF.
  ;; For mode 2 ("a"), 0 bytes means "" — never -1 — so callers can
  ;; distinguish empty-string-at-EOF from genuine EOF for line modes.
  (import "host" "read" (func $host_read (param i32) (param i32) (result i32)))
  ;; host_read_num: skip whitespace, parse one number per Lua syntax.
  ;; Returns the parsed value (int or float subtype) or nil if EOF /
  ;; no number found at the cursor.
  (import "host" "read_num" (func $host_read_num (result anyref)))
  ;; host_fmt_spec: format one value per a Lua-format directive.
  ;; spec is a LuaString like "%-10s" or "%05.2f" — the bytes from
  ;; (and including) % through the conversion char. val is the value
  ;; to format. Host parses the spec, formats, writes the result
  ;; bytes into the shared fmt_buf, returns the byte length.
  (import "host" "fmt_spec"
    (func $host_fmt_spec (param anyref) (param anyref) (result i32)))
  ;; host_parse_num: parses a Lua string per Lua semantics (whitespace
  ;; trim, optional sign, decimal int, hex int 0x..., decimal float
  ;; with optional exponent). The optional base (2..36) constrains to
  ;; integer parsing in that base; 0 means "no base specified".
  ;; Returns a Lua value: i31/struct int, $LuaFloat, or null.
  (import "host" "parse_num"
    (func $host_parse_num (param anyref) (param i32) (result anyref)))

  ;; --- singletons ---
  (global $g_true  (ref $LuaBool) (struct.new $LuaBool (i32.const 1)))
  (global $g_false (ref $LuaBool) (struct.new $LuaBool (i32.const 0)))
  (global $g_empty_upvals (ref $UpvalArr) (array.new_fixed $UpvalArr 0))
  (global $g_empty_args   (ref $ArgArr)   (array.new_fixed $ArgArr 0))
  ;; Scratch byte buffer that host_fmt writes into (set up by stdlib_init).
  (global $fmt_buf (mut (ref null $LuaArr)) (ref.null $LuaArr))

  ;; xoshiro256** state. Initial seed is fixed; user can call
  ;; math.randomseed(x [, y]) to override. Non-zero by construction.
  (global $g_rng0 (mut i64) (i64.const 0x9E3779B97F4A7C15))
  (global $g_rng1 (mut i64) (i64.const 0xBF58476D1CE4E5B9))
  (global $g_rng2 (mut i64) (i64.const 0x94D049BB133111EB))
  (global $g_rng3 (mut i64) (i64.const 0xD1B54A32D192ED03))
  ;; --- truthiness: only nil and false are falsy ---
  (func $lua_truthy (param $v anyref) (result i32)
    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then (return (struct.get $LuaBool $b
               (ref.cast (ref $LuaBool) (local.get $v))))))
    (i32.const 1))

  (func $lua_bool_to_ref (param $b i32) (result anyref)
    (if (result anyref) (local.get $b)
      (then (global.get $g_true))
      (else (global.get $g_false))))

  ;; --- numeric type predicates and accessors ---
  (func $is_int (param $v anyref) (result i32)
    (if (result i32) (ref.test (ref i31) (local.get $v))
      (then (i32.const 1))
      (else (ref.test (ref $LuaInt) (local.get $v)))))

  (func $is_float (param $v anyref) (result i32)
    (ref.test (ref $LuaFloat) (local.get $v)))

  (func $as_int (param $v anyref) (result i64)
    (if (result i64) (ref.test (ref i31) (local.get $v))
      (then (i64.extend_i32_s
              (i31.get_s (ref.cast (ref i31) (local.get $v)))))
      (else (struct.get $LuaInt $v
              (ref.cast (ref $LuaInt) (local.get $v))))))

  (func $as_float (param $v anyref) (result f64)
    (if (result f64) (call $is_float (local.get $v))
      (then (struct.get $LuaFloat $v
              (ref.cast (ref $LuaFloat) (local.get $v))))
      (else (f64.convert_i64_s (call $as_int (local.get $v))))))

  (func $make_int (param $v i64) (result anyref)
    (if (result anyref)
      (i32.and
        (i64.ge_s (local.get $v) (i64.const -1073741824))
        (i64.lt_s (local.get $v) (i64.const  1073741824)))
      (then (ref.i31 (i32.wrap_i64 (local.get $v))))
      (else (struct.new $LuaInt (local.get $v)))))

  (func $make_float (param $v f64) (result anyref)
    (struct.new $LuaFloat (local.get $v)))

  ;; --- arithmetic: int+int -> int; else promote to float ---
  (func $is_numlike (param $v anyref) (result i32)
    (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v))))

  ;; Try a binary arithmetic metamethod: lookup $key on a, then b.
  ;; Returns the metamethod's first result if found; throws otherwise.
  (func $arith_mm (param $a anyref) (param $b anyref)
                  (param $key (ref $LuaString)) (result anyref)
    (local $mm anyref)
    (local.set $mm (call $get_metamethod (local.get $a) (local.get $key)))
    (if (ref.is_null (local.get $mm))
      (then (local.set $mm (call $get_metamethod (local.get $b) (local.get $key)))))
    (if (ref.is_null (local.get $mm))
      (then (throw $LuaError (ref.null any))))
    (call $args_first (call $lua_call
      (ref.cast (ref $LuaClosure) (local.get $mm))
      (array.new_fixed $ArgArr 2 (local.get $a) (local.get $b)))))

  (func $lua_add (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))
      (then
        (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
          (then (return (call $make_int (i64.add (call $as_int (local.get $a))
                                                  (call $as_int (local.get $b)))))))
        (return (call $make_float (f64.add (call $as_float (local.get $a))
                                            (call $as_float (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_add))))

  (func $lua_sub (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))
      (then
        (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
          (then (return (call $make_int (i64.sub (call $as_int (local.get $a))
                                                  (call $as_int (local.get $b)))))))
        (return (call $make_float (f64.sub (call $as_float (local.get $a))
                                            (call $as_float (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_sub))))

  (func $lua_mul (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))
      (then
        (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
          (then (return (call $make_int (i64.mul (call $as_int (local.get $a))
                                                  (call $as_int (local.get $b)))))))
        (return (call $make_float (f64.mul (call $as_float (local.get $a))
                                            (call $as_float (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_mul))))

  ;; / always yields float (Lua 5.4/5.5)
  (func $lua_div (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))
      (then (return (call $make_float (f64.div (call $as_float (local.get $a))
                                                (call $as_float (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_div))))

  ;; Floor division: q = floor(a/b). For ints, i64.div_s truncates toward
  ;; zero, which differs from floor when signs disagree and there's a
  ;; non-zero remainder. Same correction pattern as $lua_mod: subtract 1
  ;; iff there's a remainder AND the operand signs disagree.
  (func $lua_fdiv (param $a anyref) (param $b anyref) (result anyref)
    (local $ai i64) (local $bi i64) (local $q i64) (local $r i64)
    (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then
        (local.set $ai (call $as_int (local.get $a)))
        (local.set $bi (call $as_int (local.get $b)))
        (local.set $q (i64.div_s (local.get $ai) (local.get $bi)))
        (local.set $r (i64.rem_s (local.get $ai) (local.get $bi)))
        (if (i32.and
              (i64.ne (local.get $r) (i64.const 0))
              (i64.lt_s (i64.xor (local.get $ai) (local.get $bi)) (i64.const 0)))
          (then (local.set $q (i64.sub (local.get $q) (i64.const 1)))))
        (return (call $make_int (local.get $q)))))
    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))
      (then (return (call $make_float (f64.floor
        (f64.div (call $as_float (local.get $a))
                 (call $as_float (local.get $b))))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_idiv))))

  ;; Floor modulo: a - floor(a/b)*b. Differs from truncating remainder
  ;; (i64.rem_s, C's `%`) when the operands have different signs.
  ;; Integer case: start with rem_s and adjust by +b when the remainder
  ;; is non-zero and the operand signs disagree.
  ;; Float case: a - floor(a/b)*b directly.
  (func $lua_mod (param $a anyref) (param $b anyref) (result anyref)
    (local $ai i64) (local $bi i64) (local $r i64)
    (local $af f64) (local $bf f64)
    (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then
        (local.set $ai (call $as_int (local.get $a)))
        (local.set $bi (call $as_int (local.get $b)))
        (local.set $r  (i64.rem_s (local.get $ai) (local.get $bi)))
        (if (i32.and
              (i64.ne (local.get $r) (i64.const 0))
              (i64.lt_s (i64.xor (local.get $ai) (local.get $bi)) (i64.const 0)))
          (then (local.set $r (i64.add (local.get $r) (local.get $bi)))))
        (return (call $make_int (local.get $r)))))
    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))
      (then
        (local.set $af (call $as_float (local.get $a)))
        (local.set $bf (call $as_float (local.get $b)))
        (return (call $make_float
          (f64.sub (local.get $af)
                   (f64.mul (f64.floor (f64.div (local.get $af) (local.get $bf)))
                            (local.get $bf)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_mod))))

  ;; `^` is always-float per Lua spec. Routes to host pow so that
  ;; non-integer exponents (2^0.5), negative exponents (2^-1), and
  ;; mixed-sign edge cases (NaN, inf, 0^0) all match IEEE-754 pow.
  (func $lua_pow (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))
      (then (return (call $make_float
        (call $host_math2 (i32.const 1)
          (call $as_float (local.get $a))
          (call $as_float (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_pow))))

  ;; --- bitwise --------------------------------------------------------
  ;;
  ;; Every bit op needs operands convertible to integer, per the manual's
  ;; "convertible to integer" rule (§3.4.3):
  ;;   - i31 / boxed LuaInt: use as-is
  ;;   - LuaFloat with no fractional part AND in signed-i64 range: trunc
  ;;   - anything else: bit-op falls through to the metamethod path,
  ;;     else raise. Two helpers:
  ;;       $try_to_int(v)       -> 1 iff convertible
  ;;       $as_int_unchecked(v) -> the i64 (call only after try_to_int=1)
  (func $try_to_int (param $v anyref) (result i32)
    (local $f f64)
    (if (call $is_int (local.get $v)) (then (return (i32.const 1))))
    (if (call $is_float (local.get $v))
      (then
        (local.set $f (call $as_float (local.get $v)))
        (if (i32.and
              (f64.eq (local.get $f) (f64.trunc (local.get $f)))
              (i32.and
                (f64.eq (local.get $f) (local.get $f))
                (i32.and
                  (f64.ge (local.get $f) (f64.const -9223372036854775808.0))
                  (f64.lt (local.get $f) (f64.const  9223372036854775808.0)))))
          (then (return (i32.const 1))))))
    (i32.const 0))

  ;; Returns the i64 representation of $v if convertible, else 0.
  ;; (Use together with $try_to_int's flag.)
  (func $as_int_unchecked (param $v anyref) (result i64)
    (if (result i64) (call $is_int (local.get $v))
      (then (call $as_int (local.get $v)))
      (else (i64.trunc_f64_s (call $as_float (local.get $v))))))

  ;; Common path: a binary bitop. Try both operands as ints; if both
  ;; convert, run $op; else dispatch through the metamethod $key.
  (func $bitop_band (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (i64.and (call $as_int_unchecked (local.get $a))
                 (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_band))))

  (func $bitop_bor (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (i64.or  (call $as_int_unchecked (local.get $a))
                 (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_bor))))

  (func $bitop_bxor (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (i64.xor (call $as_int_unchecked (local.get $a))
                 (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_bxor))))

  ;; Shifts: Lua semantics — logical shifts of 64-bit unsigned, negative
  ;; counts swap direction, |count| >= 64 yields 0.
  (func $do_shl (param $v i64) (param $n i64) (result i64)
    (if (i64.ge_s (local.get $n) (i64.const 64)) (then (return (i64.const 0))))
    (if (i64.le_s (local.get $n) (i64.const -64)) (then (return (i64.const 0))))
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then (return (i64.shr_u (local.get $v) (i64.sub (i64.const 0) (local.get $n))))))
    (i64.shl (local.get $v) (local.get $n)))

  (func $do_shr (param $v i64) (param $n i64) (result i64)
    (call $do_shl (local.get $v) (i64.sub (i64.const 0) (local.get $n))))

  (func $bitop_shl (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (call $do_shl (call $as_int_unchecked (local.get $a))
                       (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_shl))))

  (func $bitop_shr (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (call $do_shr (call $as_int_unchecked (local.get $a))
                       (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_shr))))

  ;; Lua-visible names (codegen emits calls to these).
  (func $lua_band (param $a anyref) (param $b anyref) (result anyref)
    (call $bitop_band (local.get $a) (local.get $b)))
  (func $lua_bor  (param $a anyref) (param $b anyref) (result anyref)
    (call $bitop_bor  (local.get $a) (local.get $b)))
  (func $lua_bxor (param $a anyref) (param $b anyref) (result anyref)
    (call $bitop_bxor (local.get $a) (local.get $b)))
  (func $lua_shl  (param $a anyref) (param $b anyref) (result anyref)
    (call $bitop_shl  (local.get $a) (local.get $b)))
  (func $lua_shr  (param $a anyref) (param $b anyref) (result anyref)
    (call $bitop_shr  (local.get $a) (local.get $b)))

  ;; Unary bitwise NOT: ~v.
  (func $lua_bnot (param $a anyref) (result anyref)
    (local $mm anyref)
    (if (call $try_to_int (local.get $a))
      (then (return (call $make_int
        (i64.xor (call $as_int_unchecked (local.get $a)) (i64.const -1))))))
    (local.set $mm (call $get_metamethod (local.get $a)
      (ref.as_non_null (global.get $g_mkey_bnot))))
    (if (ref.is_null (local.get $mm))
      (then (throw $LuaError (ref.null any))))
    (call $args_first (call $lua_call
      (ref.cast (ref $LuaClosure) (local.get $mm))
      (array.new_fixed $ArgArr 2 (local.get $a) (local.get $a)))))

  (func $lua_neg (param $a anyref) (result anyref)
    (local $mm anyref)
    (if (call $is_numlike (local.get $a))
      (then
        (if (call $is_int (local.get $a))
          (then (return (call $make_int (i64.sub (i64.const 0) (call $as_int (local.get $a)))))))
        (return (call $make_float (f64.neg (call $as_float (local.get $a)))))))
    (local.set $mm (call $get_metamethod (local.get $a)
      (ref.as_non_null (global.get $g_mkey_unm))))
    (if (ref.is_null (local.get $mm))
      (then (throw $LuaError (ref.null any))))
    ;; Per spec the metamethod is called with (a, a) for backward-compat.
    (call $args_first (call $lua_call
      (ref.cast (ref $LuaClosure) (local.get $mm))
      (array.new_fixed $ArgArr 2 (local.get $a) (local.get $a)))))


  (func $lua_not (param $a anyref) (result anyref)
    (call $lua_bool_to_ref (i32.eqz (call $lua_truthy (local.get $a)))))

  ;; `#` on:
  ;;   string -> byte length (no metamethod consulted, per spec)
  ;;   table  -> __len if defined, else the array-border length
  ;;   other  -> __len if defined, else error
  (func $lua_len (param $a anyref) (result anyref)
    (local $mm anyref)
    (if (ref.test (ref $LuaString) (local.get $a))
      (then (return (call $make_int (i64.extend_i32_u
        (array.len (struct.get $LuaString $bytes
          (ref.cast (ref $LuaString) (local.get $a)))))))))
    (if (ref.test (ref $LuaTable) (local.get $a))
      (then
        (local.set $mm (call $get_metamethod (local.get $a)
          (ref.as_non_null (global.get $g_mkey_len))))
        (if (ref.is_null (local.get $mm))
          (then (return (call $make_int (i64.extend_i32_s
            (call $tab_len (ref.cast (ref $LuaTable) (local.get $a))))))))
        (return (call $args_first (call $lua_call
          (ref.cast (ref $LuaClosure) (local.get $mm))
          (array.new_fixed $ArgArr 1 (local.get $a)))))))
    (local.set $mm (call $get_metamethod (local.get $a)
      (ref.as_non_null (global.get $g_mkey_len))))
    (if (ref.is_null (local.get $mm))
      (then (throw $LuaError (ref.null any))))
    (call $args_first (call $lua_call
      (ref.cast (ref $LuaClosure) (local.get $mm))
      (array.new_fixed $ArgArr 1 (local.get $a)))))

  ;; --- comparison ---
  (func $num_eq (param $a anyref) (param $b anyref) (result i32)
    (if (result i32)
      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (i64.eq (call $as_int (local.get $a)) (call $as_int (local.get $b))))
      (else (f64.eq (call $as_float (local.get $a)) (call $as_float (local.get $b))))))

  (func $str_eq (param $a anyref) (param $b anyref) (result i32)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr))
    (local $i i32) (local $n i32)
    (local.set $sa (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $a))))
    (local.set $sb (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $b))))
    (local.set $n (array.len (local.get $sa)))
    (if (i32.ne (local.get $n) (array.len (local.get $sb)))
      (then (return (i32.const 0))))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (if (i32.ne (array.get_u $LuaArr (local.get $sa) (local.get $i))
                  (array.get_u $LuaArr (local.get $sb) (local.get $i)))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.const 1))

  (func $lua_eq_raw (param $a anyref) (param $b anyref) (result i32)
    (local $mm anyref)
    (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
      (then (return (i32.const 1))))
    (if (i32.or  (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
      (then (return (i32.const 0))))
    (if (i32.and (ref.test (ref $LuaBool) (local.get $a))
                 (ref.test (ref $LuaBool) (local.get $b)))
      (then (return (i32.eq
        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $a)))
        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $b)))))))
    (if (i32.and
          (i32.or (call $is_int (local.get $a)) (call $is_float (local.get $a)))
          (i32.or (call $is_int (local.get $b)) (call $is_float (local.get $b))))
      (then (return (call $num_eq (local.get $a) (local.get $b)))))
    (if (i32.and (ref.test (ref $LuaString) (local.get $a))
                 (ref.test (ref $LuaString) (local.get $b)))
      (then (return (call $str_eq (local.get $a) (local.get $b)))))
    ;; Two tables: consult __eq if present, otherwise compare by identity.
    (if (i32.and (ref.test (ref $LuaTable) (local.get $a))
                 (ref.test (ref $LuaTable) (local.get $b)))
      (then
        (local.set $mm (call $get_metamethod (local.get $a) (ref.as_non_null (global.get $g_mkey_eq))))
        (if (ref.is_null (local.get $mm))
          (then (return (ref.eq (ref.cast (ref null eq) (local.get $a))
                                 (ref.cast (ref null eq) (local.get $b))))))
        (return (call $lua_truthy (call $args_first (call $lua_call
          (ref.cast (ref $LuaClosure) (local.get $mm))
          (array.new_fixed $ArgArr 2 (local.get $a) (local.get $b))))))))
    ;; Any other matched ref types (closures, etc.): identity via ref.eq.
    (if (i32.and (ref.test (ref eq) (local.get $a))
                 (ref.test (ref eq) (local.get $b)))
      (then (return (ref.eq (ref.cast (ref null eq) (local.get $a))
                             (ref.cast (ref null eq) (local.get $b))))))
    (i32.const 0))

  (func $lua_eq  (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $lua_eq_raw (local.get $a) (local.get $b))))
  (func $lua_neq (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (i32.eqz (call $lua_eq_raw (local.get $a) (local.get $b)))))

  ;; Raw equality — never consults __eq. Used by `rawequal`.
  ;; Mirrors $lua_eq_raw but for the two-table case falls back to ref.eq
  ;; identity unconditionally.
  (func $lua_rawequal (param $a anyref) (param $b anyref) (result i32)
    (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
      (then (return (i32.const 1))))
    (if (i32.or  (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
      (then (return (i32.const 0))))
    (if (i32.and (ref.test (ref $LuaBool) (local.get $a))
                 (ref.test (ref $LuaBool) (local.get $b)))
      (then (return (i32.eq
        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $a)))
        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $b)))))))
    (if (i32.and
          (i32.or (call $is_int (local.get $a)) (call $is_float (local.get $a)))
          (i32.or (call $is_int (local.get $b)) (call $is_float (local.get $b))))
      (then (return (call $num_eq (local.get $a) (local.get $b)))))
    (if (i32.and (ref.test (ref $LuaString) (local.get $a))
                 (ref.test (ref $LuaString) (local.get $b)))
      (then (return (call $str_eq (local.get $a) (local.get $b)))))
    (if (i32.and (ref.test (ref eq) (local.get $a))
                 (ref.test (ref eq) (local.get $b)))
      (then (return (ref.eq (ref.cast (ref null eq) (local.get $a))
                             (ref.cast (ref null eq) (local.get $b))))))
    (i32.const 0))

  (func $num_lt (param $a anyref) (param $b anyref) (result i32)
    (if (result i32)
      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (i64.lt_s (call $as_int (local.get $a)) (call $as_int (local.get $b))))
      (else (f64.lt (call $as_float (local.get $a)) (call $as_float (local.get $b))))))

  (func $num_le (param $a anyref) (param $b anyref) (result i32)
    (if (result i32)
      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (i64.le_s (call $as_int (local.get $a)) (call $as_int (local.get $b))))
      (else (f64.le (call $as_float (local.get $a)) (call $as_float (local.get $b))))))

  ;; Byte-wise lexicographic compare of two LuaStrings. Returns 1 if
  ;; a < b, 0 otherwise (strictly less, not <=).
  (func $str_lt (param $a anyref) (param $b anyref) (result i32)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr))
    (local $na i32) (local $nb i32) (local $i i32) (local $min i32)
    (local $ba i32) (local $bb i32)
    (local.set $sa (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $a))))
    (local.set $sb (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $b))))
    (local.set $na (array.len (local.get $sa)))
    (local.set $nb (array.len (local.get $sb)))
    (local.set $min (select (local.get $na) (local.get $nb)
                            (i32.le_s (local.get $na) (local.get $nb))))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $min)))
      (local.set $ba (array.get_u $LuaArr (local.get $sa) (local.get $i)))
      (local.set $bb (array.get_u $LuaArr (local.get $sb) (local.get $i)))
      (if (i32.lt_u (local.get $ba) (local.get $bb))
        (then (return (i32.const 1))))
      (if (i32.gt_u (local.get $ba) (local.get $bb))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    ;; equal up to the shorter length: a is < b iff a is shorter.
    (i32.lt_s (local.get $na) (local.get $nb)))

  ;; lua_lt / le / gt / ge — operand-type aware.
  ;; Both numbers -> numeric compare. Both strings -> lexicographic.
  ;; Anything else (incl. mixed types) -> Lua error.
  ;; (TODO: __lt / __le metamethods.)
  ;; Common metamethod path for < / <=: try left, then right; truthiness
  ;; of first result is the answer. Throws if neither operand defines it.
  (func $compare_mm (param $a anyref) (param $b anyref)
                    (param $key (ref $LuaString)) (result i32)
    (local $mm anyref)
    (local.set $mm (call $get_metamethod (local.get $a) (local.get $key)))
    (if (ref.is_null (local.get $mm))
      (then (local.set $mm (call $get_metamethod (local.get $b) (local.get $key)))))
    (if (ref.is_null (local.get $mm))
      (then (throw $LuaError (ref.null any))))
    (call $lua_truthy (call $args_first (call $lua_call
      (ref.cast (ref $LuaClosure) (local.get $mm))
      (array.new_fixed $ArgArr 2 (local.get $a) (local.get $b))))))

  (func $lua_lt_raw (param $a anyref) (param $b anyref) (result i32)
    (if (i32.and
          (i32.or (call $is_int (local.get $a)) (call $is_float (local.get $a)))
          (i32.or (call $is_int (local.get $b)) (call $is_float (local.get $b))))
      (then (return (call $num_lt (local.get $a) (local.get $b)))))
    (if (i32.and (ref.test (ref $LuaString) (local.get $a))
                 (ref.test (ref $LuaString) (local.get $b)))
      (then (return (call $str_lt (local.get $a) (local.get $b)))))
    (call $compare_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_lt))))

  (func $lua_le_raw (param $a anyref) (param $b anyref) (result i32)
    (if (i32.and
          (i32.or (call $is_int (local.get $a)) (call $is_float (local.get $a)))
          (i32.or (call $is_int (local.get $b)) (call $is_float (local.get $b))))
      (then (return (call $num_le (local.get $a) (local.get $b)))))
    (if (i32.and (ref.test (ref $LuaString) (local.get $a))
                 (ref.test (ref $LuaString) (local.get $b)))
      (then (return (i32.eqz (call $str_lt (local.get $b) (local.get $a))))))
    (call $compare_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_le))))

  (func $lua_lt (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $lua_lt_raw (local.get $a) (local.get $b))))
  (func $lua_le (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $lua_le_raw (local.get $a) (local.get $b))))
  (func $lua_gt (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $lua_lt_raw (local.get $b) (local.get $a))))
  (func $lua_ge (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $lua_le_raw (local.get $b) (local.get $a))))

  ;; --- string conversion + concat ---
  (func $int_to_bytes (param $v i64) (result (ref $LuaArr))
    (local $neg i32)
    (local $tmp (ref $LuaArr)) (local $n i32)
    (local $out (ref $LuaArr))
    (local $i i32) (local $j i32) (local $d i32) (local $total i32)
    (if (i64.lt_s (local.get $v) (i64.const 0))
      (then
        (local.set $neg (i32.const 1))
        (local.set $v (i64.sub (i64.const 0) (local.get $v)))))
    (local.set $tmp (array.new $LuaArr (i32.const 0) (i32.const 21)))
    (loop $lp
      (local.set $d (i32.wrap_i64 (i64.rem_u (local.get $v) (i64.const 10))))
      (local.set $v (i64.div_u (local.get $v) (i64.const 10)))
      (array.set $LuaArr (local.get $tmp) (local.get $n)
        (i32.add (local.get $d) (i32.const 48)))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br_if $lp (i64.ne (local.get $v) (i64.const 0))))
    (local.set $total (local.get $n))
    (if (local.get $neg)
      (then (local.set $total (i32.add (local.get $total) (i32.const 1)))))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $total)))
    (if (local.get $neg)
      (then
        (array.set $LuaArr (local.get $out) (i32.const 0) (i32.const 45))
        (local.set $j (i32.const 1))))
    (local.set $i (i32.sub (local.get $n) (i32.const 1)))
    (block $done (loop $cp
      (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
      (array.set $LuaArr (local.get $out) (local.get $j)
        (array.get_u $LuaArr (local.get $tmp) (local.get $i)))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $cp)))
    (local.get $out))

  ;; Float-to-bytes via host_fmt kind=6 (Lua tostring style: "1.0" for
  ;; integer-valued floats, %.14g w/ trailing-zero trim otherwise).
  (func $float_to_bytes (param $v f64) (result (ref $LuaArr))
    (local $n i32) (local $out (ref $LuaArr))
    (local.set $n (call $host_fmt (i32.const 6) (i64.const 0)
                       (local.get $v) (i32.const -1)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)
      (ref.as_non_null (global.get $fmt_buf)) (i32.const 0) (local.get $n))
    (local.get $out))

  (func $lua_tostring (param $v anyref) (result (ref $LuaString))
    (local $mm anyref) (local $r anyref)
    ;; Honour __tostring on any value with a metatable.
    (local.set $mm (call $get_metamethod (local.get $v)
      (ref.as_non_null (global.get $g_mkey_tostring))))
    (if (i32.eqz (ref.is_null (local.get $mm)))
      (then
        (local.set $r (call $args_first (call $lua_call
          (ref.cast (ref $LuaClosure) (local.get $mm))
          (array.new_fixed $ArgArr 1 (local.get $v)))))
        (if (i32.eqz (ref.test (ref $LuaString) (local.get $r)))
          (then (throw $LuaError (ref.null any))))
        (return (ref.cast (ref $LuaString) (local.get $r)))))
    (if (ref.is_null (local.get $v))
      (then (return (struct.new $LuaString
        (array.new_data $LuaArr $str_data (i32.const 0) (i32.const 3))))))
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then (return (if (result (ref $LuaString))
        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v)))
        (then (struct.new $LuaString
          (array.new_data $LuaArr $str_data (i32.const 3) (i32.const 4))))
        (else (struct.new $LuaString
          (array.new_data $LuaArr $str_data (i32.const 7) (i32.const 5))))))))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return (ref.cast (ref $LuaString) (local.get $v)))))
    (if (call $is_int (local.get $v))
      (then (return (struct.new $LuaString
        (call $int_to_bytes (call $as_int (local.get $v)))))))
    (if (call $is_float (local.get $v))
      (then (return (struct.new $LuaString
        (call $float_to_bytes (call $as_float (local.get $v)))))))
    ;; tables and functions: short placeholder (Lua usually appends an
    ;; address-like suffix; we don't, documented as a gap in stdlib.md).
    ;; Data segment layout (see codegen):
    ;;   niltruefalse<float>numberstringtablefunction...
    ;;    0    3    7   12     19    25   31   36
    (if (ref.test (ref $LuaTable) (local.get $v))
      (then (return (struct.new $LuaString
        (array.new_data $LuaArr $str_data (i32.const 31) (i32.const 5))))))   ;; "table"
    (if (ref.test (ref $LuaClosure) (local.get $v))
      (then (return (struct.new $LuaString
        (array.new_data $LuaArr $str_data (i32.const 36) (i32.const 8))))))   ;; "function"
    ;; Unknown type: nil placeholder so we never trap.
    (struct.new $LuaString
      (array.new_data $LuaArr $str_data (i32.const 0) (i32.const 3))))

  ;; Per Lua, `..` only accepts string or number operands (TODO: __concat
  ;; metamethod). Anything else raises.
  (func $is_concatable (param $v anyref) (result i32)
    (i32.or (ref.test (ref $LuaString) (local.get $v))
            (i32.or (call $is_int (local.get $v))
                    (call $is_float (local.get $v)))))

  (func $lua_concat (param $a anyref) (param $b anyref) (result anyref)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr)) (local $out (ref $LuaArr))
    (local $na i32) (local $nb i32)
    (if (i32.eqz (i32.and (call $is_concatable (local.get $a))
                          (call $is_concatable (local.get $b))))
      (then (return (call $arith_mm (local.get $a) (local.get $b)
                      (ref.as_non_null (global.get $g_mkey_concat))))))
    (local.set $sa (struct.get $LuaString $bytes (call $lua_tostring (local.get $a))))
    (local.set $sb (struct.get $LuaString $bytes (call $lua_tostring (local.get $b))))
    (local.set $na (array.len (local.get $sa)))
    (local.set $nb (array.len (local.get $sb)))
    (local.set $out (array.new $LuaArr (i32.const 0)
                       (i32.add (local.get $na) (local.get $nb))))
    (array.copy $LuaArr $LuaArr
      (local.get $out) (i32.const 0)
      (local.get $sa)  (i32.const 0) (local.get $na))
    (array.copy $LuaArr $LuaArr
      (local.get $out) (local.get $na)
      (local.get $sb)  (i32.const 0) (local.get $nb))
    (struct.new $LuaString (local.get $out)))

  ;; --- tables (open-addressing hash index over dense key/value arrays) ---
  (func $tab_new (result (ref $LuaTable))
    (struct.new $LuaTable
      (ref.null $TArr) (ref.null $TArr)
      (i32.const 0) (i32.const 0)
      (ref.null $IArr) (i32.const 0)
      (ref.null $LuaTable)))

  ;; Grow keys/vals arrays to at least new_cap; copies old contents.
  (func $tab_grow (param $t (ref $LuaTable)) (param $new_cap i32)
    (local $nk (ref $TArr)) (local $nv (ref $TArr))
    (local $oldk (ref null $TArr)) (local $oldv (ref null $TArr))
    (local $n i32)
    (local.set $nk (array.new $TArr (ref.null any) (local.get $new_cap)))
    (local.set $nv (array.new $TArr (ref.null any) (local.get $new_cap)))
    (local.set $oldk (struct.get $LuaTable $keys (local.get $t)))
    (local.set $oldv (struct.get $LuaTable $vals (local.get $t)))
    (local.set $n    (struct.get $LuaTable $n    (local.get $t)))
    (if (ref.is_null (local.get $oldk))
      (then)
      (else
        (array.copy $TArr $TArr (local.get $nk) (i32.const 0)
          (ref.as_non_null (local.get $oldk)) (i32.const 0) (local.get $n))
        (array.copy $TArr $TArr (local.get $nv) (i32.const 0)
          (ref.as_non_null (local.get $oldv)) (i32.const 0) (local.get $n))))
    (struct.set $LuaTable $keys (local.get $t) (local.get $nk))
    (struct.set $LuaTable $vals (local.get $t) (local.get $nv))
    (struct.set $LuaTable $cap  (local.get $t) (local.get $new_cap)))

  ;; Hash any Lua value to an i32. The only requirement for correctness
  ;; is that values that compare equal (via $lua_eq_raw) hash equally —
  ;; specifically Lua's int↔float equivalence at integer values. We mix
  ;; with a small FNV-style step so different types don't trivially
  ;; collide at hash 0.
  (func $lua_hash (param $v anyref) (result i32)
    (local $h i32) (local $bytes (ref null $LuaArr)) (local $i i32) (local $n i32)
    (local $f f64)
    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
    (if (call $is_int (local.get $v))
      (then (return (i32.xor
        (i32.wrap_i64 (call $as_int (local.get $v)))
        (i32.wrap_i64 (i64.shr_u (call $as_int (local.get $v)) (i64.const 32)))))))
    (if (call $is_float (local.get $v))
      (then
        (local.set $f (call $as_float (local.get $v)))
        ;; integer-valued floats must hash like the equivalent int.
        (if (f64.eq (local.get $f) (f64.trunc (local.get $f)))
          (then
            (if (i32.and (f64.ge (local.get $f) (f64.const -9.2233720368547758e+18))
                         (f64.lt (local.get $f) (f64.const  9.2233720368547758e+18)))
              (then (return (i32.xor
                (i32.wrap_i64 (i64.trunc_f64_s (local.get $f)))
                (i32.wrap_i64 (i64.shr_u (i64.trunc_f64_s (local.get $f)) (i64.const 32))))))))
          (else))
        (return (i32.xor
          (i32.wrap_i64 (i64.reinterpret_f64 (local.get $f)))
          (i32.wrap_i64 (i64.shr_u (i64.reinterpret_f64 (local.get $f)) (i64.const 32)))))))
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then (return (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v))))))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then
        (local.set $bytes (struct.get $LuaString $bytes
                            (ref.cast (ref $LuaString) (local.get $v))))
        (local.set $h (i32.const -2128831035)) ;; FNV offset basis
        (local.set $n (array.len (ref.as_non_null (local.get $bytes))))
        (block $done (loop $lp
          (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
          (local.set $h (i32.mul
            (i32.xor (local.get $h)
              (array.get_u $LuaArr (ref.as_non_null (local.get $bytes)) (local.get $i)))
            (i32.const 16777619)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $lp)))
        (return (local.get $h))))
    ;; Tables, closures: identity isn't observable in WasmGC, so all
    ;; such keys hash to 0 and resolve via linear probe over the index.
    (i32.const 0))

  ;; Rebuild the hash index from keys[0..n]. new_mask is (cap-1) where
  ;; cap is a power of two ≥ next_pow2(2*n).
  (func $tab_index_rebuild (param $t (ref $LuaTable)) (param $new_mask i32)
    (local $idx (ref $IArr)) (local $keys (ref null $TArr))
    (local $i i32) (local $n i32) (local $h i32) (local $cap i32)
    (local.set $cap (i32.add (local.get $new_mask) (i32.const 1)))
    (local.set $idx (array.new $IArr (i32.const 0) (local.get $cap)))
    (local.set $keys (struct.get $LuaTable $keys (local.get $t)))
    (local.set $n (struct.get $LuaTable $n (local.get $t)))
    (if (i32.eqz (ref.is_null (local.get $keys)))
      (then
        (block $kdone (loop $klp
          (br_if $kdone (i32.ge_s (local.get $i) (local.get $n)))
          (local.set $h (i32.and (local.get $new_mask) (call $lua_hash
            (array.get $TArr (ref.as_non_null (local.get $keys)) (local.get $i)))))
          (block $place (loop $probe
            (if (i32.eqz (array.get $IArr (local.get $idx) (local.get $h)))
              (then
                (array.set $IArr (local.get $idx) (local.get $h)
                  (i32.add (local.get $i) (i32.const 1)))
                (br $place)))
            (local.set $h (i32.and (local.get $new_mask)
              (i32.add (local.get $h) (i32.const 1))))
            (br $probe)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $klp)))))
    (struct.set $LuaTable $idx  (local.get $t) (local.get $idx))
    (struct.set $LuaTable $mask (local.get $t) (local.get $new_mask)))

  ;; Probe the hash index for a key. Returns position in keys[] (>=0)
  ;; on hit, -1 on miss. Caller must ensure $idx is non-null (i.e. n>0
  ;; — empty tables short-circuit in tab_find).
  (func $tab_index_lookup (param $t (ref $LuaTable)) (param $k anyref) (result i32)
    (local $idx (ref $IArr)) (local $keys (ref $TArr))
    (local $mask i32) (local $h i32) (local $slot i32) (local $pos i32)
    (local.set $idx (ref.as_non_null (struct.get $LuaTable $idx (local.get $t))))
    (local.set $keys (ref.as_non_null (struct.get $LuaTable $keys (local.get $t))))
    (local.set $mask (struct.get $LuaTable $mask (local.get $t)))
    (local.set $h (i32.and (local.get $mask) (call $lua_hash (local.get $k))))
    (loop $probe
      (local.set $slot (array.get $IArr (local.get $idx) (local.get $h)))
      (if (i32.eqz (local.get $slot)) (then (return (i32.const -1))))
      (local.set $pos (i32.sub (local.get $slot) (i32.const 1)))
      (if (call $lua_eq_raw
            (array.get $TArr (local.get $keys) (local.get $pos))
            (local.get $k))
        (then (return (local.get $pos))))
      (local.set $h (i32.and (local.get $mask)
        (i32.add (local.get $h) (i32.const 1))))
      (br $probe))
    (i32.const -1))

  ;; Public lookup: returns position in keys[] (>=0) or -1 on miss.
  (func $tab_find (param $t (ref $LuaTable)) (param $k anyref) (result i32)
    (if (i32.eqz (struct.get $LuaTable $n (local.get $t)))
      (then (return (i32.const -1))))
    (call $tab_index_lookup (local.get $t) (local.get $k)))

  (func $tab_get_raw (param $t (ref $LuaTable)) (param $k anyref) (result anyref)
    (local $i i32) (local $vals (ref null $TArr))
    (local.set $i (call $tab_find (local.get $t) (local.get $k)))
    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return (ref.null any))))
    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
    (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $i)))

  ;; Lookup that walks the __index metamethod chain (with cycle limit).
  (func $tab_get (param $t (ref $LuaTable)) (param $k anyref) (result anyref)
    (local $v anyref) (local $mt (ref null $LuaTable)) (local $idx anyref)
    (local $cur (ref $LuaTable)) (local $depth i32)
    (local.set $cur (local.get $t))
    (local.set $depth (i32.const 64))
    (block $done (result anyref) (loop $lp
      (local.set $v (call $tab_get_raw (local.get $cur) (local.get $k)))
      (if (i32.eqz (ref.is_null (local.get $v))) (then (br $done (local.get $v))))
      (local.set $mt (struct.get $LuaTable $meta (local.get $cur)))
      (if (ref.is_null (local.get $mt)) (then (br $done (ref.null any))))
      (local.set $idx (call $tab_get_raw (ref.as_non_null (local.get $mt))
                                          (ref.as_non_null (global.get $g_mkey_index))))
      (if (ref.is_null (local.get $idx)) (then (br $done (ref.null any))))
      (if (ref.test (ref $LuaTable) (local.get $idx))
        (then
          (local.set $cur (ref.cast (ref $LuaTable) (local.get $idx)))
          (local.set $depth (i32.sub (local.get $depth) (i32.const 1)))
          (br_if $done (ref.null any)
            (i32.le_s (local.get $depth) (i32.const 0)))
          (br $lp)))
      (if (ref.test (ref $LuaClosure) (local.get $idx))
        (then (br $done
          (call $args_first (call $lua_call
            (ref.cast (ref $LuaClosure) (local.get $idx))
            (array.new_fixed $ArgArr 2 (local.get $cur) (local.get $k)))))))
      (br $done (ref.null any))
    )))

  (func $get_metamethod (param $v anyref) (param $key (ref $LuaString)) (result anyref)
    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v))) (then (return (ref.null any))))
    (local.set $t (ref.cast (ref $LuaTable) (local.get $v)))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt)) (then (return (ref.null any))))
    (call $tab_get_raw (ref.as_non_null (local.get $mt)) (local.get $key)))

  (global $g_mkey_index     (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_newindex  (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_add       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_sub       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_mul       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_div       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_mod       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_pow       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_unm       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_idiv      (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_band      (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_bor       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_bxor      (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_shl       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_shr       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_bnot      (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_concat    (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_len       (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_eq        (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_lt        (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_le        (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_call      (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_tostring  (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_metatable (mut (ref null $LuaString)) (ref.null $LuaString))

  ;; --- _G: the global-environment table ---
  ;; Every Lua global (user-declared, library, builtin) is an entry in
  ;; this table. \$stdlib_init populates it; codegen emits \$tab_get /
  ;; \$tab_set against it for every global read/write.
  (global $g_globals (mut (ref null $LuaTable)) (ref.null $LuaTable))
  (global $g_tab_str    (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_empty_str  (mut (ref null $LuaString)) (ref.null $LuaString))

  (func $tab_set (param $t (ref $LuaTable)) (param $k anyref) (param $v anyref)
    (local $i i32) (local $n i32) (local $cap i32) (local $mask i32)
    (local $keys (ref null $TArr)) (local $vals (ref null $TArr))
    (local $idx (ref null $IArr)) (local $h i32) (local $slot i32)
    (local.set $i (call $tab_find (local.get $t) (local.get $k)))
    (if (i32.ge_s (local.get $i) (i32.const 0))
      (then
        ;; existing key: update or delete
        (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
        (if (ref.is_null (local.get $v))
          (then
            ;; delete: swap-with-last and rebuild the index so we don't
            ;; have to chase tombstones. n is small relative to lookups
            ;; in the typical workload, so the rebuild cost is amortised.
            (local.set $n (i32.sub (struct.get $LuaTable $n (local.get $t)) (i32.const 1)))
            (local.set $keys (struct.get $LuaTable $keys (local.get $t)))
            (if (i32.lt_s (local.get $i) (local.get $n))
              (then
                (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $i)
                  (array.get $TArr (ref.as_non_null (local.get $keys)) (local.get $n)))
                (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $i)
                  (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $n)))))
            (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $n) (ref.null any))
            (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $n) (ref.null any))
            (struct.set $LuaTable $n (local.get $t) (local.get $n))
            (call $tab_index_rebuild (local.get $t)
              (struct.get $LuaTable $mask (local.get $t))))
          (else
            (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $i) (local.get $v))))
        (return)))
    ;; not found: if value is nil, no-op; else append
    (if (ref.is_null (local.get $v)) (then (return)))
    (local.set $n (struct.get $LuaTable $n (local.get $t)))
    (local.set $cap (struct.get $LuaTable $cap (local.get $t)))
    (if (i32.ge_s (local.get $n) (local.get $cap))
      (then
        (call $tab_grow (local.get $t)
          (if (result i32) (i32.eqz (local.get $cap))
            (then (i32.const 4))
            (else (i32.mul (local.get $cap) (i32.const 2)))))))
    ;; Make sure the hash index has capacity for one more entry at <=50%
    ;; load. Initial size 8; doubled each time. Rebuild from keys[0..n].
    (local.set $idx (struct.get $LuaTable $idx (local.get $t)))
    (if (ref.is_null (local.get $idx))
      (then (call $tab_index_rebuild (local.get $t) (i32.const 7)))
      (else
        (local.set $mask (struct.get $LuaTable $mask (local.get $t)))
        (if (i32.ge_u (i32.shl (i32.add (local.get $n) (i32.const 1)) (i32.const 1))
                      (i32.add (local.get $mask) (i32.const 1)))
          (then (call $tab_index_rebuild (local.get $t)
            (i32.or (i32.shl (local.get $mask) (i32.const 1)) (i32.const 1)))))))
    ;; Append to keys/vals and probe-insert into idx.
    (local.set $keys (struct.get $LuaTable $keys (local.get $t)))
    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
    (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $n) (local.get $k))
    (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $n) (local.get $v))
    (struct.set $LuaTable $n (local.get $t) (i32.add (local.get $n) (i32.const 1)))
    (local.set $idx (struct.get $LuaTable $idx (local.get $t)))
    (local.set $mask (struct.get $LuaTable $mask (local.get $t)))
    (local.set $h (i32.and (local.get $mask) (call $lua_hash (local.get $k))))
    (loop $probe
      (local.set $slot (array.get $IArr (ref.as_non_null (local.get $idx)) (local.get $h)))
      (if (i32.eqz (local.get $slot))
        (then
          (array.set $IArr (ref.as_non_null (local.get $idx)) (local.get $h)
            (i32.add (local.get $n) (i32.const 1)))
          (return)))
      (local.set $h (i32.and (local.get $mask)
        (i32.add (local.get $h) (i32.const 1))))
      (br $probe)))

  ;; `t[k] = v` with __newindex dispatch. Used by user-code assignments.
  ;; Table-constructor inserts go through bare \$tab_set since they target
  ;; freshly built tables with no metatable.
  ;;
  ;; Lua: if t[k] is already present, do a raw set (no metamethod). Otherwise,
  ;; if t has __newindex:
  ;;   - table form: do lua_tabset on that table (recurses, with cycle guard)
  ;;   - function form: call __newindex(t, k, v)
  ;; If __newindex is absent, do the raw set.
  (func $lua_tabset (param $v anyref) (param $k anyref) (param $val anyref)
    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable))
    (local $mm anyref) (local $depth i32)
    (block $exit (loop $top
      ;; If $v isn't a table, fall through to the metamethod path on the
      ;; value's metatable (rare; objects with __index/__newindex but no
      ;; backing table). For now require a table.
      (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v)))
        (then (throw $LuaError (ref.null any))))
      (local.set $t (ref.cast (ref $LuaTable) (local.get $v)))
      ;; If key is already present, raw-set (no MM consulted).
      (if (i32.ge_s (call $tab_find (local.get $t) (local.get $k)) (i32.const 0))
        (then (call $tab_set (local.get $t) (local.get $k) (local.get $val))
              (br $exit)))
      ;; Look up __newindex on the metatable.
      (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
      (if (ref.is_null (local.get $mt))
        (then (call $tab_set (local.get $t) (local.get $k) (local.get $val))
              (br $exit)))
      (local.set $mm (call $tab_get_raw (ref.as_non_null (local.get $mt))
        (ref.as_non_null (global.get $g_mkey_newindex))))
      (if (ref.is_null (local.get $mm))
        (then (call $tab_set (local.get $t) (local.get $k) (local.get $val))
              (br $exit)))
      ;; Function form: call __newindex(t, k, val) and we're done.
      (if (ref.test (ref $LuaClosure) (local.get $mm))
        (then
          (drop (call $lua_call (ref.cast (ref $LuaClosure) (local.get $mm))
                  (array.new_fixed $ArgArr 3
                    (local.get $v) (local.get $k) (local.get $val))))
          (br $exit)))
      ;; Table form: continue with $v = mm. Cycle cap matches __index.
      (local.set $v (local.get $mm))
      (local.set $depth (i32.add (local.get $depth) (i32.const 1)))
      (if (i32.gt_s (local.get $depth) (i32.const 200))
        (then (throw $LuaError (ref.null any))))
      (br $top))))

  ;; Length via array-border rule: count k=1,2,3,... while t[k] is non-nil.
  (func $tab_len (param $t (ref $LuaTable)) (result i32)
    (local $i i32) (local $k anyref)
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (local.set $k (call $tab_get (local.get $t) (ref.i31 (local.get $i))))
      (br_if $done (ref.is_null (local.get $k)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.sub (local.get $i) (i32.const 1)))

  ;; --- numeric-for helper ---
  (func $for_step_positive (param $s anyref) (result i32)
    (if (result i32) (call $is_int (local.get $s))
      (then (i64.ge_s (call $as_int (local.get $s)) (i64.const 0)))
      (else (f64.ge (call $as_float (local.get $s)) (f64.const 0)))))

  ;; Real Lua errors at runtime when a numeric-for step is zero.
  (func $for_check_step (param $s anyref)
    (if (call $is_int (local.get $s))
      (then
        (if (i64.eqz (call $as_int (local.get $s)))
          (then (throw $LuaError (struct.new $LuaString
            (array.new_data $LuaArr $str_data (i32.const 75) (i32.const 18)))))))
      (else
        (if (f64.eq (call $as_float (local.get $s)) (f64.const 0))
          (then (throw $LuaError (struct.new $LuaString
            (array.new_data $LuaArr $str_data (i32.const 75) (i32.const 18)))))))))

  ;; --- closure dispatch + multi-value helpers + print builtin ---
  (func $lua_call (param $closure (ref $LuaClosure)) (param $args (ref $ArgArr))
                  (result (ref $ArgArr))
    (call_ref $LuaFn
      (local.get $closure)
      (local.get $args)
      (struct.get $LuaClosure $code (local.get $closure))))

  ;; Call any Lua value as a function, walking __call metamethods. Throws
  ;; a Lua-shaped "attempt to call a non-function value" $LuaError if
  ;; the chain bottoms out on a non-callable. A small iteration cap
  ;; keeps a cyclic __call from looping forever.
  (func $lua_call_any (param $v anyref) (param $args (ref $ArgArr))
                      (result (ref $ArgArr))
    (local $mm anyref) (local $i i32)
    (local.set $i (i32.const 0))
    (loop $resolve
      (if (ref.test (ref $LuaClosure) (local.get $v))
        (then (return (call $lua_call
                        (ref.cast (ref $LuaClosure) (local.get $v))
                        (local.get $args)))))
      (local.set $mm (call $get_metamethod (local.get $v)
                       (ref.as_non_null (global.get $g_mkey_call))))
      (if (ref.is_null (local.get $mm))
        (then (throw $LuaError (struct.new $LuaString
          (array.new_data $LuaArr $str_data (i32.const 93) (i32.const 36))))))
      ;; Prepend the original callee so __call sees `self`.
      (local.set $args (call $merge_args
        (array.new_fixed $ArgArr 1 (local.get $v))
        (local.get $args)))
      (local.set $v (local.get $mm))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $resolve (i32.lt_s (local.get $i) (i32.const 200))))
    (throw $LuaError (struct.new $LuaString
      (array.new_data $LuaArr $str_data (i32.const 93) (i32.const 36)))))

  (func $args_first (param $args (ref $ArgArr)) (result anyref)
    (if (result anyref) (i32.eqz (array.len (local.get $args)))
      (then (ref.null any))
      (else (array.get $ArgArr (local.get $args) (i32.const 0)))))

  (func $args_at (param $args (ref $ArgArr)) (param $i i32) (result anyref)
    (if (result anyref) (i32.ge_u (local.get $i) (array.len (local.get $args)))
      (then (ref.null any))
      (else (array.get $ArgArr (local.get $args) (local.get $i)))))

  (func $args_slice (param $a (ref $ArgArr)) (param $from i32) (result (ref $ArgArr))
    (local $n i32) (local $out (ref $ArgArr))
    (local.set $n (array.len (local.get $a)))
    (if (i32.ge_s (local.get $from) (local.get $n))
      (then (return (global.get $g_empty_args))))
    (local.set $out (array.new $ArgArr (ref.null any)
                       (i32.sub (local.get $n) (local.get $from))))
    (array.copy $ArgArr $ArgArr
      (local.get $out) (i32.const 0)
      (local.get $a)   (local.get $from)
      (i32.sub (local.get $n) (local.get $from)))
    (local.get $out))

  ;; tab_append_args(t, pos, args): t[pos+i] = args[i] for i in 0..#args-1.
  (func $tab_append_args (param $t (ref $LuaTable)) (param $pos i32) (param $args (ref $ArgArr))
    (local $i i32) (local $n i32)
    (local.set $n (array.len (local.get $args)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (call $tab_set (local.get $t)
        (ref.i31 (i32.add (local.get $pos) (local.get $i)))
        (array.get $ArgArr (local.get $args) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  (func $merge_args (param $a (ref $ArgArr)) (param $b (ref $ArgArr)) (result (ref $ArgArr))
    (local $na i32) (local $nb i32) (local $out (ref $ArgArr))
    (local.set $na (array.len (local.get $a)))
    (local.set $nb (array.len (local.get $b)))
    (local.set $out (array.new $ArgArr (ref.null any)
                       (i32.add (local.get $na) (local.get $nb))))
    (array.copy $ArgArr $ArgArr
      (local.get $out) (i32.const 0)
      (local.get $a)   (i32.const 0) (local.get $na))
    (array.copy $ArgArr $ArgArr
      (local.get $out) (local.get $na)
      (local.get $b)   (i32.const 0) (local.get $nb))
    (local.get $out))

  (tag $LuaError (param anyref))

  ;; Real-Lua print: tostring each arg, join with TAB, host prints with a
  ;; trailing newline. Zero args -> just a newline.
  (func $builtin_print (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $acc anyref)
    (local.set $n (array.len (local.get $args)))
    (if (i32.eqz (local.get $n))
      (then
        (call $host_print (ref.as_non_null (global.get $g_empty_str)))
        (return (global.get $g_empty_args))))
    ;; Single arg: tostring it so __tostring fires, then hand to host.
    ;; (For values without __tostring, $lua_tostring covers all the
    ;; primitive cases — float formatting matches the host's renderer.)
    (if (i32.eq (local.get $n) (i32.const 1))
      (then
        (local.set $acc (call $args_at (local.get $args) (i32.const 0)))
        (if (i32.eqz (ref.is_null (call $get_metamethod (local.get $acc)
              (ref.as_non_null (global.get $g_mkey_tostring)))))
          (then (local.set $acc (call $lua_tostring (local.get $acc)))))
        (call $host_print (local.get $acc))
        (return (global.get $g_empty_args))))
    ;; Multi-arg: stringify each value (so nil/bool/table render fine
    ;; without tripping the concat type check), then join with TAB.
    (local.set $acc (call $lua_tostring (call $args_at (local.get $args) (i32.const 0))))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $acc
        (call $lua_concat
          (call $lua_concat (local.get $acc)
                            (ref.as_non_null (global.get $g_tab_str)))
          (call $lua_tostring (call $args_at (local.get $args) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $host_print (local.get $acc))
    (global.get $g_empty_args))

  (func $builtin_error (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (throw $LuaError (call $args_at (local.get $args) (i32.const 0)))
    ;; unreachable, but typechecker needs a tail expression:
    (global.get $g_empty_args))

  ;; pcall(f, ...): calls f with the remaining args. Returns (true, results...)
  ;; on success; (false, err) on caught $LuaError.
  (func $builtin_pcall (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $callee (ref $LuaClosure))
    (local $f_args (ref $ArgArr))
    (local $n_total i32) (local $n_fargs i32) (local $i i32)
    (local $err anyref) (local $results (ref $ArgArr)) (local $r2 (ref $ArgArr))
    (local.set $n_total (array.len (local.get $args)))
    (if (i32.eqz (local.get $n_total))
      (then (throw $LuaError (ref.null any))))
    (local.set $callee
      (ref.cast (ref $LuaClosure) (array.get $ArgArr (local.get $args) (i32.const 0))))
    (local.set $n_fargs (i32.sub (local.get $n_total) (i32.const 1)))
    (local.set $f_args (array.new $ArgArr (ref.null any) (local.get $n_fargs)))
    (block $copied (loop $cp
      (br_if $copied (i32.ge_s (local.get $i) (local.get $n_fargs)))
      (array.set $ArgArr (local.get $f_args) (local.get $i)
        (array.get $ArgArr (local.get $args)
          (i32.add (local.get $i) (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $cp)))
    (block $catch_err (result anyref)
      ;; success path: build (true, results...) and return.
      (local.set $results
        (try_table (result (ref $ArgArr)) (catch $LuaError $catch_err)
          (call $lua_call (local.get $callee) (local.get $f_args))))
      ;; prepend true
      (local.set $r2 (array.new $ArgArr (ref.null any)
        (i32.add (array.len (local.get $results)) (i32.const 1))))
      (array.set $ArgArr (local.get $r2) (i32.const 0) (global.get $g_true))
      (array.copy $ArgArr $ArgArr (local.get $r2) (i32.const 1)
        (local.get $results) (i32.const 0) (array.len (local.get $results)))
      (return (local.get $r2)))
    ;; catch path: stack has the error anyref
    (local.set $err)
    (array.new_fixed $ArgArr 2 (global.get $g_false) (local.get $err)))

  ;; xpcall(f, msgh, ...): like pcall, but on error calls msgh(err) and
  ;; uses its first return value as the error returned. If msgh itself
  ;; throws, the new error replaces the original.
  (func $builtin_xpcall (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $callee (ref $LuaClosure)) (local $msgh (ref $LuaClosure))
    (local $f_args (ref $ArgArr))
    (local $n_total i32) (local $n_fargs i32) (local $i i32)
    (local $err anyref) (local $results (ref $ArgArr)) (local $r2 (ref $ArgArr))
    (local $handled anyref)
    (local.set $n_total (array.len (local.get $args)))
    (if (i32.lt_s (local.get $n_total) (i32.const 2))
      (then (throw $LuaError (ref.null any))))
    (local.set $callee
      (ref.cast (ref $LuaClosure) (array.get $ArgArr (local.get $args) (i32.const 0))))
    (local.set $msgh
      (ref.cast (ref $LuaClosure) (array.get $ArgArr (local.get $args) (i32.const 1))))
    (local.set $n_fargs (i32.sub (local.get $n_total) (i32.const 2)))
    (local.set $f_args (array.new $ArgArr (ref.null any) (local.get $n_fargs)))
    (block $copied (loop $cp
      (br_if $copied (i32.ge_s (local.get $i) (local.get $n_fargs)))
      (array.set $ArgArr (local.get $f_args) (local.get $i)
        (array.get $ArgArr (local.get $args)
          (i32.add (local.get $i) (i32.const 2))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $cp)))
    (block $catch_err (result anyref)
      (local.set $results
        (try_table (result (ref $ArgArr)) (catch $LuaError $catch_err)
          (call $lua_call (local.get $callee) (local.get $f_args))))
      ;; success: prepend true.
      (local.set $r2 (array.new $ArgArr (ref.null any)
        (i32.add (array.len (local.get $results)) (i32.const 1))))
      (array.set $ArgArr (local.get $r2) (i32.const 0) (global.get $g_true))
      (array.copy $ArgArr $ArgArr (local.get $r2) (i32.const 1)
        (local.get $results) (i32.const 0) (array.len (local.get $results)))
      (return (local.get $r2)))
    ;; error path: stack has $err.
    (local.set $err)
    ;; Call msgh(err) — itself wrapped so its throw doesn't escape xpcall.
    (block $msgh_throw (result anyref)
      (local.set $handled (call $args_first
        (try_table (result (ref $ArgArr)) (catch $LuaError $msgh_throw)
          (call $lua_call (local.get $msgh)
            (array.new_fixed $ArgArr 1 (local.get $err))))))
      (return (array.new_fixed $ArgArr 2 (global.get $g_false) (local.get $handled))))
    ;; msgh threw: stack has its own error value.
    (local.set $handled)
    (array.new_fixed $ArgArr 2 (global.get $g_false) (local.get $handled)))

  ;; warn(...): hand a concatenated string to the host. Accepts (and
  ;; silently ignores) the "@on"/"@off" control messages.
  (func $builtin_warn (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $acc anyref) (local $first anyref)
    (local $bytes (ref $LuaArr))
    (local.set $n (array.len (local.get $args)))
    (if (i32.eqz (local.get $n)) (then (return (global.get $g_empty_args))))
    ;; Drop control messages "@on" and "@off" silently when they appear
    ;; as a sole string argument; this matches reference Lua's no-op
    ;; behaviour for those when warnings are already in the user's
    ;; chosen mode.
    (local.set $first (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.and (i32.eq (local.get $n) (i32.const 1))
                 (ref.test (ref $LuaString) (local.get $first)))
      (then
        (local.set $bytes (struct.get $LuaString $bytes
          (ref.cast (ref $LuaString) (local.get $first))))
        (if (i32.and (i32.ge_s (array.len (local.get $bytes)) (i32.const 1))
                     (i32.eq (array.get_u $LuaArr (local.get $bytes) (i32.const 0))
                             (i32.const 64)))   ;; '@'
          (then (return (global.get $g_empty_args))))))
    ;; Concatenate all args (each tostring'd) and hand to host_warn.
    (local.set $acc (call $lua_tostring (call $args_at (local.get $args) (i32.const 0))))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $acc (call $lua_concat (local.get $acc)
        (call $lua_tostring (call $args_at (local.get $args) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $host_warn (local.get $acc))
    (global.get $g_empty_args))

  ;; --- additional top-level builtins ---
  (func $builtin_assert (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (if (call $lua_truthy (call $args_at (local.get $args) (i32.const 0)))
      (then (return (local.get $args))))
    ;; failed: throw the message (args[1]) or a default
    (throw $LuaError (call $args_at (local.get $args) (i32.const 1)))
    (global.get $g_empty_args))

  ;; rawlen(v): byte length for strings, table-border length for tables.
  ;; Errors otherwise. Bypasses __len (we don't honour __len yet, but the
  ;; contract is: never consult it).
  (func $builtin_rawlen (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (ref.test (ref $LuaTable) (local.get $v))
      (then (return (array.new_fixed $ArgArr 1
              (call $make_int (i64.extend_i32_s
                (call $tab_len (ref.cast (ref $LuaTable) (local.get $v))))))))
      (else (if (ref.test (ref $LuaString) (local.get $v))
        (then (return (array.new_fixed $ArgArr 1
                (call $make_int (i64.extend_i32_u
                  (array.len (struct.get $LuaString $bytes
                    (ref.cast (ref $LuaString) (local.get $v))))))))))))
    (throw $LuaError (ref.null any))
    (global.get $g_empty_args))

  ;; rawset(t, k, v): table write without consulting __newindex.
  ;; First arg must be a table. Key must not be nil or NaN. Returns the
  ;; table (so callers can chain).
  (func $builtin_rawset (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t anyref) (local $k anyref) (local $f f64)
    (local.set $t (call $args_at (local.get $args) (i32.const 0)))
    (local.set $k (call $args_at (local.get $args) (i32.const 1)))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $t)))
      (then (throw $LuaError (ref.null any))))
    (if (ref.is_null (local.get $k))
      (then (throw $LuaError (ref.null any))))
    ;; NaN check: a float key whose value != itself.
    (if (call $is_float (local.get $k))
      (then
        (local.set $f (call $as_float (local.get $k)))
        (if (f64.ne (local.get $f) (local.get $f))
          (then (throw $LuaError (ref.null any))))))
    (call $tab_set
      (ref.cast (ref $LuaTable) (local.get $t))
      (local.get $k)
      (call $args_at (local.get $args) (i32.const 2)))
    (array.new_fixed $ArgArr 1 (local.get $t)))

  ;; rawget(t, k): table read without consulting __index.
  ;; First arg must be a table; second is the key. Returns nil on miss.
  (func $builtin_rawget (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t anyref)
    (local.set $t (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $t)))
      (then (throw $LuaError (ref.null any))))
    (array.new_fixed $ArgArr 1
      (call $tab_get_raw
        (ref.cast (ref $LuaTable) (local.get $t))
        (call $args_at (local.get $args) (i32.const 1)))))

  ;; rawequal(a, b): equality without consulting __eq.
  (func $builtin_rawequal (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $lua_bool_to_ref
        (call $lua_rawequal
          (call $args_at (local.get $args) (i32.const 0))
          (call $args_at (local.get $args) (i32.const 1))))))

  ;; select(n, ...): if n is the string "#", returns the count of extras.
  ;; Otherwise n is an integer index (1-based); returns args from that index on.
  (func $builtin_select (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $sel anyref) (local $bytes (ref $LuaArr)) (local $n i32) (local $idx i32)
    (local.set $n (array.len (local.get $args)))
    (if (i32.eqz (local.get $n)) (then (throw $LuaError (ref.null any))))
    (local.set $sel (call $args_at (local.get $args) (i32.const 0)))
    (if (ref.test (ref $LuaString) (local.get $sel))
      (then
        (local.set $bytes (struct.get $LuaString $bytes
                            (ref.cast (ref $LuaString) (local.get $sel))))
        (if (i32.and (i32.eq (array.len (local.get $bytes)) (i32.const 1))
                     (i32.eq (array.get_u $LuaArr (local.get $bytes) (i32.const 0))
                             (i32.const 35)))   ;; '#'
          (then (return (array.new_fixed $ArgArr 1
                  (call $make_int (i64.extend_i32_s
                    (i32.sub (local.get $n) (i32.const 1))))))))))
    ;; numeric index. Negative means count from the end.
    (local.set $idx (i32.wrap_i64 (call $as_int (local.get $sel))))
    (if (i32.lt_s (local.get $idx) (i32.const 0))
      (then (local.set $idx (i32.add (i32.sub (local.get $n) (i32.const 1))
                                      (i32.add (local.get $idx) (i32.const 1))))))
    (if (i32.lt_s (local.get $idx) (i32.const 1))
      (then (throw $LuaError (ref.null any))))
    (call $args_slice (local.get $args) (local.get $idx)))

  ;; io.write — like print but no trailing newline, no tab between args
  (func $builtin_io_write (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $acc anyref)
    (local.set $n (array.len (local.get $args)))
    (if (i32.eqz (local.get $n)) (then (return (global.get $g_empty_args))))
    (if (i32.eq (local.get $n) (i32.const 1))
      (then
        (call $host_write_raw (call $args_at (local.get $args) (i32.const 0)))
        (return (global.get $g_empty_args))))
    ;; Tostring each arg first so nil/bool/table render via the
    ;; standard rules instead of tripping concat's type check.
    (local.set $acc (call $lua_tostring (call $args_at (local.get $args) (i32.const 0))))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $acc (call $lua_concat (local.get $acc)
                       (call $lua_tostring (call $args_at (local.get $args) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $host_write_raw (local.get $acc))
    (global.get $g_empty_args))

  ;; io.read — single-line reader. Host writes the line into $fmt_buf and
  ;; returns its length; -1 means EOF, in which case we return nil.
  ;; io.read(...) — one result per format arg.
  ;; Formats:
  ;;   "l"          line, no trailing \n (default if no args)
  ;;   "L"          line, with trailing \n
  ;;   "a"          read all remaining (empty string at EOF, not nil)
  ;;   "n"          parse one number; returns nil if no number at cursor
  ;;   integer N    read up to N bytes (returns "" at EOF for N == 0,
  ;;                otherwise nil at EOF)
  ;; Older Lua's leading '*' in format strings (e.g. "*l") is tolerated.
  (func $builtin_io_read (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $nargs i32) (local $i i32) (local $fmt anyref)
    (local $bytes (ref $LuaArr)) (local $blen i32) (local $b0 i32) (local $b1 i32)
    (local $mode i32) (local $count i32) (local $written i32)
    (local $out (ref $ArgArr)) (local $val anyref)
    (local.set $nargs (array.len (local.get $args)))
    ;; No args: behave as io.read("l").
    (if (i32.eqz (local.get $nargs))
      (then
        (local.set $written (call $host_read (i32.const 0) (i32.const 0)))
        (if (i32.lt_s (local.get $written) (i32.const 0))
          (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
        (return (array.new_fixed $ArgArr 1
          (call $fmt_buf_to_str (local.get $written))))))
    (local.set $out (array.new $ArgArr (ref.null any) (local.get $nargs)))
    (block $loopdone (loop $loop
      (br_if $loopdone (i32.ge_s (local.get $i) (local.get $nargs)))
      (local.set $fmt (call $args_at (local.get $args) (local.get $i)))
      (if (ref.test (ref $LuaString) (local.get $fmt))
        (then
          (local.set $bytes (struct.get $LuaString $bytes
            (ref.cast (ref $LuaString) (local.get $fmt))))
          (local.set $blen (array.len (local.get $bytes)))
          ;; Strip an optional leading '*' (legacy compat).
          (local.set $b0 (i32.const 0))
          (if (i32.and (i32.gt_s (local.get $blen) (i32.const 0))
                       (i32.eq (array.get_u $LuaArr (local.get $bytes) (i32.const 0))
                               (i32.const 42)))   ;; '*'
            (then (local.set $b0 (i32.const 1))))
          (if (i32.le_s (local.get $blen) (local.get $b0))
            (then (throw $LuaError (ref.null any))))
          (local.set $b1 (array.get_u $LuaArr (local.get $bytes) (local.get $b0)))
          ;; map first non-'*' char to a mode
          (if (i32.eq (local.get $b1) (i32.const 108))         ;; 'l'
            (then (local.set $mode (i32.const 0)))
            (else (if (i32.eq (local.get $b1) (i32.const 76))  ;; 'L'
              (then (local.set $mode (i32.const 1)))
              (else (if (i32.eq (local.get $b1) (i32.const 97)) ;; 'a'
                (then (local.set $mode (i32.const 2)))
                (else (if (i32.eq (local.get $b1) (i32.const 110)) ;; 'n'
                  (then (local.set $mode (i32.const -1)))    ;; sentinel: number
                  (else (throw $LuaError (ref.null any))))))))))
          (if (i32.eq (local.get $mode) (i32.const -1))
            (then (local.set $val (call $host_read_num)))
            (else
              (local.set $written
                (call $host_read (local.get $mode) (i32.const 0)))
              (if (i32.lt_s (local.get $written) (i32.const 0))
                (then (local.set $val (ref.null any)))
                (else (local.set $val (call $fmt_buf_to_str (local.get $written))))))))
        (else
          ;; integer count — exact N bytes
          (local.set $count (i32.wrap_i64 (call $as_int (local.get $fmt))))
          (if (i32.lt_s (local.get $count) (i32.const 0))
            (then (throw $LuaError (ref.null any))))
          (local.set $written (call $host_read (i32.const 3) (local.get $count)))
          (if (i32.lt_s (local.get $written) (i32.const 0))
            (then
              (if (i32.eqz (local.get $count))
                (then (local.set $val (call $fmt_buf_to_str (i32.const 0))))
                (else (local.set $val (ref.null any)))))
            (else (local.set $val (call $fmt_buf_to_str (local.get $written)))))))
      (array.set $ArgArr (local.get $out) (local.get $i) (local.get $val))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $out))

  (func $builtin_type (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref) (local $bytes (ref null $LuaArr)) (local $b (ref null $LuaString))
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    ;; pick canonical type-name bytes via existing $str_data offsets if any;
    ;; otherwise materialize on the fly. We just store the names inline.
    (if (ref.is_null (local.get $v))
      (then (local.set $bytes (call $bytes_of_lit (i32.const 19))))
      (else (if (ref.test (ref $LuaBool) (local.get $v))
        (then (local.set $bytes (call $bytes_of_lit (i32.const 7))))
        (else (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
          (then (local.set $bytes (call $bytes_of_lit (i32.const 0))))
          (else (if (ref.test (ref $LuaString) (local.get $v))
            (then (local.set $bytes (call $bytes_of_lit (i32.const 1))))
            (else (if (ref.test (ref $LuaTable) (local.get $v))
              (then (local.set $bytes (call $bytes_of_lit (i32.const 2))))
              (else (local.set $bytes (call $bytes_of_lit (i32.const 3)))))))))))))
    (local.set $b (struct.new $LuaString (ref.as_non_null (local.get $bytes))))
    (array.new_fixed $ArgArr 1 (ref.as_non_null (local.get $b))))

  (func $builtin_tostring (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $lua_tostring (call $args_at (local.get $args) (i32.const 0)))))

  ;; tonumber(v [, base])
  ;;   - numbers: passthrough (when base absent)
  ;;   - strings: parsed per Lua rules — whitespace trim, optional sign,
  ;;              decimal int, 0x... hex int, decimal float with optional
  ;;              exponent. With a base argument, only integer parsing
  ;;              in that base is attempted.
  ;;   - anything else: nil
  ;; The parser lives host-side (see runtime/host.mjs); WAT just dispatches.
  (func $builtin_tonumber (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref) (local $base i32) (local $nargs i32)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (local.set $nargs (array.len (local.get $args)))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $base (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 1)))))))
    ;; with no base, numeric arguments pass through unchanged.
    (if (i32.eqz (local.get $base))
      (then
        (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
          (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))))
    ;; otherwise, only strings can be parsed; non-strings yield nil.
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $v)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (array.new_fixed $ArgArr 1
      (call $host_parse_num (local.get $v) (local.get $base))))

  ;; next(t, k): returns next key/value pair, or nothing when exhausted.
  (func $builtin_next (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $k anyref)
    (local $idx i32) (local $n i32)
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $k (call $args_at (local.get $args) (i32.const 1)))
    (if (ref.is_null (local.get $k))
      (then (local.set $idx (i32.const 0)))
      (else
        (local.set $idx (i32.add (call $tab_find (local.get $t) (local.get $k))
                                  (i32.const 1)))))
    (local.set $n (struct.get $LuaTable $n (local.get $t)))
    (if (i32.ge_s (local.get $idx) (local.get $n))
      (then (return (global.get $g_empty_args))))
    (array.new_fixed $ArgArr 2
      (array.get $TArr (ref.as_non_null (struct.get $LuaTable $keys (local.get $t)))
                       (local.get $idx))
      (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))
                       (local.get $idx))))

  (func $builtin_pairs (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 3
      (global.get $g_builtin_next)
      (call $args_at (local.get $args) (i32.const 0))
      (ref.null any)))

  ;; ipairs_iter: takes (t, prev_k) where prev_k is an int. Returns next int
  ;; key and t[next_k], or empty when t[next_k] is nil.
  (func $builtin_ipairs_iter (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $k i32) (local $v anyref) (local $kref anyref)
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $k (i32.add
      (i31.get_s (ref.cast (ref i31) (call $args_at (local.get $args) (i32.const 1))))
      (i32.const 1)))
    (local.set $kref (ref.i31 (local.get $k)))
    (local.set $v (call $tab_get (local.get $t) (local.get $kref)))
    (if (ref.is_null (local.get $v))
      (then (return (global.get $g_empty_args))))
    (array.new_fixed $ArgArr 2 (local.get $kref) (local.get $v)))

  (func $builtin_ipairs (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 3
      (global.get $g_builtin_ipairs_iter)
      (call $args_at (local.get $args) (i32.const 0))
      (ref.i31 (i32.const 0))))

  (func $builtin_setmetatable (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $mt anyref) (local $cur (ref null $LuaTable))
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $mt (call $args_at (local.get $args) (i32.const 1)))
    ;; Protect: if the existing metatable carries __metatable, error.
    (local.set $cur (struct.get $LuaTable $meta (local.get $t)))
    (if (i32.eqz (ref.is_null (local.get $cur)))
      (then
        (if (i32.eqz (ref.is_null
              (call $tab_get_raw (ref.as_non_null (local.get $cur))
                (ref.as_non_null (global.get $g_mkey_metatable)))))
          (then (throw $LuaError (ref.null any))))))
    (if (ref.is_null (local.get $mt))
      (then (struct.set $LuaTable $meta (local.get $t) (ref.null $LuaTable)))
      (else (struct.set $LuaTable $meta (local.get $t)
        (ref.cast (ref $LuaTable) (local.get $mt)))))
    (array.new_fixed $ArgArr 1 (local.get $t)))

  (func $builtin_getmetatable (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable)) (local $guard anyref)
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    ;; If __metatable is set, return it instead of the real metatable.
    (local.set $guard (call $tab_get_raw (ref.as_non_null (local.get $mt))
      (ref.as_non_null (global.get $g_mkey_metatable))))
    (if (i32.eqz (ref.is_null (local.get $guard)))
      (then (return (array.new_fixed $ArgArr 1 (local.get $guard)))))
    (array.new_fixed $ArgArr 1 (ref.as_non_null (local.get $mt))))

  ;; --- math library ---
  (func $builtin_math_floor (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (call $is_int (local.get $v))
      (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))
    (array.new_fixed $ArgArr 1
      (call $make_int (i64.trunc_f64_s (f64.floor (call $as_float (local.get $v)))))))

  (func $builtin_math_abs (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref) (local $i i64)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (call $is_int (local.get $v))
      (then
        (local.set $i (call $as_int (local.get $v)))
        (if (i64.lt_s (local.get $i) (i64.const 0))
          (then (local.set $i (i64.sub (i64.const 0) (local.get $i)))))
        (return (array.new_fixed $ArgArr 1 (call $make_int (local.get $i))))))
    (array.new_fixed $ArgArr 1
      (call $make_float (f64.abs (call $as_float (local.get $v))))))

  (func $builtin_math_sqrt (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $make_float (f64.sqrt (call $as_float
        (call $args_at (local.get $args) (i32.const 0)))))))

  ;; Transcendentals all route through host_math with a kind index.
  (func $math_via_host (param $kind i32) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $make_float (call $host_math (local.get $kind)
        (call $as_float (call $args_at (local.get $args) (i32.const 0)))))))
  (func $builtin_math_sin  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 0) (local.get $args)))
  (func $builtin_math_cos  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 1) (local.get $args)))
  (func $builtin_math_tan  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 2) (local.get $args)))
  (func $builtin_math_asin (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 3) (local.get $args)))
  (func $builtin_math_acos (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 4) (local.get $args)))
  ;; math.atan(y [, x]) — 1-arg: atan(y). 2-arg: atan2(y, x).
  (func $builtin_math_atan (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (return (array.new_fixed $ArgArr 1
        (call $make_float (call $host_math2 (i32.const 0)
          (call $as_float (call $args_at (local.get $args) (i32.const 0)))
          (call $as_float (call $args_at (local.get $args) (i32.const 1)))))))))
    (call $math_via_host (i32.const 5) (local.get $args)))
  (func $builtin_math_exp  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 6) (local.get $args)))
  ;; math.log(x [, base]) — 1-arg: ln(x). 2-arg: log_base(x) = ln(x)/ln(base).
  (func $builtin_math_log (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $lx f64) (local $lb f64)
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then
        (local.set $lx (call $host_math (i32.const 7)
          (call $as_float (call $args_at (local.get $args) (i32.const 0)))))
        (local.set $lb (call $host_math (i32.const 7)
          (call $as_float (call $args_at (local.get $args) (i32.const 1)))))
        (return (array.new_fixed $ArgArr 1
          (call $make_float (f64.div (local.get $lx) (local.get $lb)))))))
    (call $math_via_host (i32.const 7) (local.get $args)))

  ;; math.fmod(x, y) — truncating remainder (rounds quotient toward zero).
  ;; Distinct from Lua's `%` operator (which is floor-modulo).
  ;; If both args are integers: integer result; y == 0 raises.
  ;; Otherwise: float result via x - trunc(x/y)*y.
  (func $builtin_math_fmod (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $a anyref) (local $b anyref) (local $iy i64)
    (local $fx f64) (local $fy f64)
    (local.set $a (call $args_at (local.get $args) (i32.const 0)))
    (local.set $b (call $args_at (local.get $args) (i32.const 1)))
    (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then
        (local.set $iy (call $as_int (local.get $b)))
        (if (i64.eqz (local.get $iy))
          (then (throw $LuaError (ref.null any))))
        (return (array.new_fixed $ArgArr 1
          (call $make_int (i64.rem_s (call $as_int (local.get $a))
                                      (local.get $iy)))))))
    (local.set $fx (call $as_float (local.get $a)))
    (local.set $fy (call $as_float (local.get $b)))
    (array.new_fixed $ArgArr 1
      (call $make_float
        (f64.sub (local.get $fx)
                 (f64.mul (f64.trunc (f64.div (local.get $fx) (local.get $fy)))
                          (local.get $fy))))))

  ;; math.modf(x) — returns (integral, fractional).
  ;; Integral part is returned as integer if it fits in i64, else as float.
  ;; Fractional part is always a float.
  (func $builtin_math_modf (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $x f64) (local $ip f64) (local $fp f64)
    (local $out (ref $ArgArr)) (local $head anyref)
    (local.set $x (call $as_float (call $args_at (local.get $args) (i32.const 0))))
    (local.set $ip (f64.trunc (local.get $x)))
    (local.set $fp (f64.sub (local.get $x) (local.get $ip)))
    ;; Integral as int if representable: |ip| < 2^63 and ip == ip (not NaN).
    (if (i32.and
          (f64.eq (local.get $ip) (local.get $ip))
          (i32.and
            (f64.ge (local.get $ip) (f64.const -9223372036854775808.0))
            (f64.lt (local.get $ip) (f64.const  9223372036854775808.0))))
      (then (local.set $head (call $make_int (i64.trunc_f64_s (local.get $ip)))))
      (else (local.set $head (call $make_float (local.get $ip)))))
    (local.set $out (array.new $ArgArr (ref.null any) (i32.const 2)))
    (array.set $ArgArr (local.get $out) (i32.const 0) (local.get $head))
    (array.set $ArgArr (local.get $out) (i32.const 1) (call $make_float (local.get $fp)))
    (local.get $out))

  ;; math.tointeger(v) — int passthrough; float with integer value → int;
  ;; anything else (incl. non-integer float, nil, etc.) → nil.
  ;; (Strings: this implementation does NOT accept strings; per the manual
  ;; it should accept anything `tonumber` accepts, which is a future
  ;; refinement.)
  (func $builtin_math_tointeger (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref) (local $f f64) (local $i i64)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (call $is_int (local.get $v))
      (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))
    (if (call $is_float (local.get $v))
      (then
        (local.set $f (call $as_float (local.get $v)))
        ;; representable as i64 AND has no fractional part
        (if (i32.and
              (f64.eq (local.get $f) (f64.trunc (local.get $f)))
              (i32.and
                (f64.eq (local.get $f) (local.get $f))      ;; not NaN
                (i32.and
                  (f64.ge (local.get $f) (f64.const -9223372036854775808.0))
                  (f64.lt (local.get $f) (f64.const  9223372036854775808.0)))))
          (then (return (array.new_fixed $ArgArr 1
                  (call $make_int (i64.trunc_f64_s (local.get $f)))))))))
    (array.new_fixed $ArgArr 1 (ref.null any)))

  ;; math.type(v) — "integer" / "float" / nil.
  (func $builtin_math_type (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (call $is_int (local.get $v))
      (then (return (array.new_fixed $ArgArr 1
              (struct.new $LuaString
                (array.new_fixed $LuaArr 7
                  (i32.const 105) (i32.const 110) (i32.const 116)
                  (i32.const 101) (i32.const 103) (i32.const 101)
                  (i32.const 114)))))))
    (if (call $is_float (local.get $v))
      (then (return (array.new_fixed $ArgArr 1
              (struct.new $LuaString
                (array.new_fixed $LuaArr 5
                  (i32.const 102) (i32.const 108) (i32.const 111)
                  (i32.const 97)  (i32.const 116)))))))
    (array.new_fixed $ArgArr 1 (ref.null any)))

  ;; math.ult(m, n) — unsigned i64 less-than. Both args must be integers.
  (func $builtin_math_ult (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $lua_bool_to_ref
        (i64.lt_u
          (call $as_int (call $args_at (local.get $args) (i32.const 0)))
          (call $as_int (call $args_at (local.get $args) (i32.const 1)))))))

  ;; xoshiro256** single step. Mutates the four state globals; returns the
  ;; output u64. Algorithm from Blackman & Vigna's public description.
  (func $rng_next (result i64)
    (local $s0 i64) (local $s1 i64) (local $s2 i64) (local $s3 i64)
    (local $result i64) (local $t i64)
    (local.set $s0 (global.get $g_rng0))
    (local.set $s1 (global.get $g_rng1))
    (local.set $s2 (global.get $g_rng2))
    (local.set $s3 (global.get $g_rng3))
    ;; result = rotl(s1 * 5, 7) * 9
    (local.set $result (i64.mul (local.get $s1) (i64.const 5)))
    (local.set $result (i64.rotl (local.get $result) (i64.const 7)))
    (local.set $result (i64.mul (local.get $result) (i64.const 9)))
    ;; t = s1 << 17
    (local.set $t (i64.shl (local.get $s1) (i64.const 17)))
    ;; s2 ^= s0;  s3 ^= s1;  s1 ^= s2;  s0 ^= s3;  s2 ^= t;  s3 = rotl(s3, 45)
    (local.set $s2 (i64.xor (local.get $s2) (local.get $s0)))
    (local.set $s3 (i64.xor (local.get $s3) (local.get $s1)))
    (local.set $s1 (i64.xor (local.get $s1) (local.get $s2)))
    (local.set $s0 (i64.xor (local.get $s0) (local.get $s3)))
    (local.set $s2 (i64.xor (local.get $s2) (local.get $t)))
    (local.set $s3 (i64.rotl (local.get $s3) (i64.const 45)))
    (global.set $g_rng0 (local.get $s0))
    (global.set $g_rng1 (local.get $s1))
    (global.set $g_rng2 (local.get $s2))
    (global.set $g_rng3 (local.get $s3))
    (local.get $result))

  ;; SplitMix64 — used to expand a single user seed into our 4-word state
  ;; without leaving any state word zero (a degenerate xoshiro seed).
  (func $rng_splitmix64 (param $x i64) (result i64)
    (local $z i64)
    (local.set $z (i64.add (local.get $x) (i64.const 0x9E3779B97F4A7C15)))
    (local.set $z (i64.mul
      (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30)))
      (i64.const 0xBF58476D1CE4E5B9)))
    (local.set $z (i64.mul
      (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27)))
      (i64.const 0x94D049BB133111EB)))
    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))

  ;; math.random([m [, n]])
  ;;   0 args: float in [0, 1)
  ;;   1 arg n  (n != 0): integer in [1, n]
  ;;   1 arg 0       : full-range integer (any i64)
  ;;   2 args m, n : integer in [m, n]
  (func $builtin_math_random (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $r i64) (local $lo i64) (local $hi i64) (local $range i64)
    (local $bits i64) (local $f f64)
    (local.set $n (array.len (local.get $args)))
    (if (i32.eqz (local.get $n))
      (then
        ;; Take the top 53 bits as the mantissa of a float in [0, 1).
        (local.set $bits (i64.shr_u (call $rng_next) (i64.const 11)))
        (local.set $f (f64.mul
          (f64.convert_i64_u (local.get $bits))
          (f64.const 0x1p-53)))
        (return (array.new_fixed $ArgArr 1 (call $make_float (local.get $f))))))
    ;; integer modes
    (local.set $hi (call $as_int (call $args_at (local.get $args) (i32.const 0))))
    (local.set $lo (i64.const 1))
    (if (i32.gt_u (local.get $n) (i32.const 1))
      (then
        (local.set $lo (local.get $hi))
        (local.set $hi (call $as_int (call $args_at (local.get $args) (i32.const 1))))))
    ;; full-range mode: math.random(0)
    (if (i32.and (i32.eq (local.get $n) (i32.const 1))
                 (i64.eqz (local.get $hi)))
      (then (return (array.new_fixed $ArgArr 1
              (call $make_int (call $rng_next))))))
    (if (i64.gt_s (local.get $lo) (local.get $hi))
      (then (throw $LuaError (ref.null any))))
    ;; range = hi - lo + 1; pick uniform via mod (good enough for our
    ;; purposes; the bias is < 1/2^32 for any range < 2^32).
    (local.set $range (i64.add (i64.sub (local.get $hi) (local.get $lo)) (i64.const 1)))
    (local.set $r (i64.rem_u (call $rng_next) (local.get $range)))
    (array.new_fixed $ArgArr 1
      (call $make_int (i64.add (local.get $lo) (local.get $r)))))

  ;; math.randomseed([x [, y]]) — set the PRNG state, return (seed1, seed2).
  ;; With one seed x, expand via SplitMix64 to fill all four state words.
  ;; With two seeds, use them as (s0, s2) and derive (s1, s3) the same way.
  ;; With no seeds, reseed from a fixed combination (we don't have a clock).
  (func $builtin_math_randomseed (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $x i64) (local $y i64)
    (local $out (ref $ArgArr))
    (local.set $n (array.len (local.get $args)))
    (if (i32.eqz (local.get $n))
      (then
        ;; deterministic re-seed in absence of a host clock
        (local.set $x (i64.const 0x243F6A8885A308D3))
        (local.set $y (i64.const 0x13198A2E03707344)))
      (else
        (local.set $x (call $as_int (call $args_at (local.get $args) (i32.const 0))))
        (if (i32.gt_u (local.get $n) (i32.const 1))
          (then (local.set $y (call $as_int (call $args_at (local.get $args) (i32.const 1)))))
          (else (local.set $y (i64.const 0))))))
    (global.set $g_rng0 (call $rng_splitmix64 (local.get $x)))
    (global.set $g_rng1 (call $rng_splitmix64
      (i64.add (local.get $x) (i64.const 1))))
    (global.set $g_rng2 (call $rng_splitmix64
      (i64.add (local.get $y) (i64.const 2))))
    (global.set $g_rng3 (call $rng_splitmix64
      (i64.add (local.get $y) (i64.const 3))))
    (local.set $out (array.new $ArgArr (ref.null any) (i32.const 2)))
    (array.set $ArgArr (local.get $out) (i32.const 0) (call $make_int (local.get $x)))
    (array.set $ArgArr (local.get $out) (i32.const 1) (call $make_int (local.get $y)))
    (local.get $out))

  ;; math.deg(x) — radians to degrees.
  (func $builtin_math_deg (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $make_float
        (f64.mul (call $as_float (call $args_at (local.get $args) (i32.const 0)))
                 (f64.const 57.29577951308232)))))   ;; 180 / pi

  ;; math.rad(x) — degrees to radians.
  (func $builtin_math_rad (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $make_float
        (f64.mul (call $as_float (call $args_at (local.get $args) (i32.const 0)))
                 (f64.const 0.017453292519943295))))) ;; pi / 180

  (func $builtin_math_ceil (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (call $is_int (local.get $v))
      (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))
    (array.new_fixed $ArgArr 1
      (call $make_int (i64.trunc_f64_s (f64.ceil (call $as_float (local.get $v)))))))

  ;; math.min/max: pick the smaller/larger of args[0..n-1] using $num_lt.
  (func $builtin_math_min (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $best anyref) (local $v anyref)
    (local.set $n (array.len (local.get $args)))
    (local.set $best (call $args_at (local.get $args) (i32.const 0)))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $v (call $args_at (local.get $args) (local.get $i)))
      (if (call $num_lt (local.get $v) (local.get $best))
        (then (local.set $best (local.get $v))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (local.get $best)))

  (func $builtin_math_max (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $best anyref) (local $v anyref)
    (local.set $n (array.len (local.get $args)))
    (local.set $best (call $args_at (local.get $args) (i32.const 0)))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $v (call $args_at (local.get $args) (local.get $i)))
      (if (call $num_lt (local.get $best) (local.get $v))
        (then (local.set $best (local.get $v))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (local.get $best)))

  ;; table.insert(t, v)         -> append at #t+1
  ;; table.insert(t, pos, v)    -> shift t[pos..#t] up, t[pos] = v
  (func $builtin_table_insert (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $n i32) (local $pos i32) (local $v anyref)
    (local $i i32)
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $n (call $tab_len (local.get $t)))
    (if (i32.eq (array.len (local.get $args)) (i32.const 2))
      (then
        (local.set $v (call $args_at (local.get $args) (i32.const 1)))
        (call $tab_set (local.get $t) (ref.i31 (i32.add (local.get $n) (i32.const 1))) (local.get $v))
        (return (global.get $g_empty_args))))
    ;; 3-arg form
    (local.set $pos (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $v (call $args_at (local.get $args) (i32.const 2)))
    ;; shift elements pos..n up by 1
    (local.set $i (local.get $n))
    (block $done (loop $lp
      (br_if $done (i32.lt_s (local.get $i) (local.get $pos)))
      (call $tab_set (local.get $t)
        (ref.i31 (i32.add (local.get $i) (i32.const 1)))
        (call $tab_get (local.get $t) (ref.i31 (local.get $i))))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $tab_set (local.get $t) (ref.i31 (local.get $pos)) (local.get $v))
    (global.get $g_empty_args))

  ;; table.remove(t [, pos])    -> default pos = #t; returns removed value
  (func $builtin_table_remove (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $n i32) (local $pos i32)
    (local $removed anyref) (local $i i32)
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $n (call $tab_len (local.get $t)))
    (if (i32.eqz (local.get $n))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (local.set $pos
        (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1))))))
      (else (local.set $pos (local.get $n))))
    (local.set $removed (call $tab_get (local.get $t) (ref.i31 (local.get $pos))))
    ;; shift elements pos+1..n down by 1
    (local.set $i (local.get $pos))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (call $tab_set (local.get $t) (ref.i31 (local.get $i))
        (call $tab_get (local.get $t) (ref.i31 (i32.add (local.get $i) (i32.const 1)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $tab_set (local.get $t) (ref.i31 (local.get $n)) (ref.null any))
    (array.new_fixed $ArgArr 1 (local.get $removed)))

  ;; table.concat(t [, sep])    -> string concatenation of t[1..#t]
  (func $builtin_table_concat (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $sep anyref) (local $acc anyref)
    (local $n i32) (local $i i32)
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (local.set $sep (call $args_at (local.get $args) (i32.const 1))))
      (else (local.set $sep (ref.as_non_null (global.get $g_empty_str)))))
    (local.set $n (call $tab_len (local.get $t)))
    (if (i32.eqz (local.get $n))
      (then (return (array.new_fixed $ArgArr 1 (ref.as_non_null (global.get $g_empty_str))))))
    (local.set $acc (call $tab_get (local.get $t) (ref.i31 (i32.const 1))))
    (local.set $i (i32.const 2))
    (block $done (loop $lp
      (br_if $done (i32.gt_s (local.get $i) (local.get $n)))
      (local.set $acc (call $lua_concat
        (call $lua_concat (local.get $acc) (local.get $sep))
        (call $tab_get (local.get $t) (ref.i31 (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (call $lua_tostring (local.get $acc))))

  ;; table.unpack(t [, i [, j]]) -> t[i], t[i+1], ..., t[j].
  ;; Defaults: i = 1, j = #t. Returns no values when j < i.
  ;; --- table.sort ---
  ;;
  ;; Comparator wrapper: if $cmp is null, use the built-in `<`; otherwise
  ;; invoke the user closure with (a, b) and take the truthiness of its
  ;; first return.
  (func $cmp_lt (param $cmp (ref null $LuaClosure))
                (param $a anyref) (param $b anyref) (result i32)
    (if (result i32) (ref.is_null (local.get $cmp))
      (then (call $lua_lt_raw (local.get $a) (local.get $b)))
      (else (call $lua_truthy
        (call $args_first
          (call $lua_call (ref.as_non_null (local.get $cmp))
            (array.new_fixed $ArgArr 2 (local.get $a) (local.get $b))))))))

  ;; In-place quicksort over the array part [lo, hi]. Uses Lomuto
  ;; partitioning with the last element as pivot, then "recurse on the
  ;; smaller side, iterate on the larger" to keep stack depth O(log n).
  (func $qsort (param $t (ref $LuaTable))
               (param $lo i32) (param $hi i32)
               (param $cmp (ref null $LuaClosure))
    (local $i i32) (local $j i32)
    (local $pivot anyref) (local $tmp anyref) (local $a anyref)
    (block $exit (loop $top
      (br_if $exit (i32.ge_s (local.get $lo) (local.get $hi)))
      (local.set $pivot (call $tab_get (local.get $t) (ref.i31 (local.get $hi))))
      (local.set $i (i32.sub (local.get $lo) (i32.const 1)))
      (local.set $j (local.get $lo))
      (block $pdone (loop $ploop
        (br_if $pdone (i32.ge_s (local.get $j) (local.get $hi)))
        (local.set $a (call $tab_get (local.get $t) (ref.i31 (local.get $j))))
        (if (call $cmp_lt (local.get $cmp) (local.get $a) (local.get $pivot))
          (then
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (local.set $tmp (call $tab_get (local.get $t) (ref.i31 (local.get $i))))
            (call $tab_set (local.get $t) (ref.i31 (local.get $i)) (local.get $a))
            (call $tab_set (local.get $t) (ref.i31 (local.get $j)) (local.get $tmp))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $ploop)))
      ;; place pivot at index $i+1
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (local.set $tmp (call $tab_get (local.get $t) (ref.i31 (local.get $i))))
      (call $tab_set (local.get $t) (ref.i31 (local.get $i)) (local.get $pivot))
      (call $tab_set (local.get $t) (ref.i31 (local.get $hi)) (local.get $tmp))
      ;; recurse smaller, iterate larger
      (if (i32.lt_s (i32.sub (local.get $i) (local.get $lo))
                    (i32.sub (local.get $hi) (local.get $i)))
        (then
          (call $qsort (local.get $t) (local.get $lo)
                       (i32.sub (local.get $i) (i32.const 1)) (local.get $cmp))
          (local.set $lo (i32.add (local.get $i) (i32.const 1))))
        (else
          (call $qsort (local.get $t) (i32.add (local.get $i) (i32.const 1))
                       (local.get $hi) (local.get $cmp))
          (local.set $hi (i32.sub (local.get $i) (i32.const 1)))))
      (br $top))))

  ;; table.sort(t [, cmp]) — in-place sort of t[1..#t].
  (func $builtin_table_sort (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $cmp (ref null $LuaClosure)) (local $n i32)
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (local.set $cmp (ref.cast (ref $LuaClosure)
              (call $args_at (local.get $args) (i32.const 1))))))
    (local.set $n (call $tab_len (local.get $t)))
    (if (i32.gt_s (local.get $n) (i32.const 1))
      (then (call $qsort (local.get $t) (i32.const 1) (local.get $n) (local.get $cmp))))
    (global.get $g_empty_args))

  ;; table.create(nseq [, nrec]): allocates a table with pre-sized
  ;; storage. The table starts empty (n=0); the pre-sizing means
  ;; subsequent inserts up to nseq+nrec won't trigger a grow.
  ;; Our table representation has one combined keys/vals array, so we
  ;; treat both hints as a single capacity request.
  (func $builtin_table_create (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $nseq i32) (local $nrec i32) (local $cap i32)
    (local.set $t (call $tab_new))
    (local.set $nseq (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 0)))))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (local.set $nrec
              (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1)))))))
    (local.set $cap (i32.add (local.get $nseq) (local.get $nrec)))
    (if (i32.gt_s (local.get $cap) (i32.const 0))
      (then (call $tab_grow (local.get $t) (local.get $cap))))
    (array.new_fixed $ArgArr 1 (local.get $t)))

  ;; table.move(a1, f, e, t [, a2]): copy a1[f..e] to (a2 or a1)[t..].
  ;; Returns the destination table. Handles overlap (a1 == a2 with
  ;; t in [f, e]) by choosing iteration direction.
  ;; If f > e, nothing to copy; still returns the destination.
  (func $builtin_table_move (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $a1 (ref $LuaTable)) (local $a2 (ref $LuaTable))
    (local $f i32) (local $e i32) (local $t i32)
    (local $n i32) (local $i i32) (local $v anyref)
    (local.set $a1 (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $f  (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $e  (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 2)))))
    (local.set $t  (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 3)))))
    ;; optional 5th arg: destination table; defaults to a1.
    (local.set $a2 (local.get $a1))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 4))
      (then (local.set $a2
              (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 4))))))
    ;; nothing to do if range is empty (f > e).
    (if (i32.le_s (local.get $f) (local.get $e))
      (then
        (local.set $n (i32.add (i32.sub (local.get $e) (local.get $f)) (i32.const 1)))
        ;; If dst overlaps src and t > f, iterate backward to avoid clobbering.
        ;; Backward iteration: i = n-1 ..= 0, dst[t+i] = src[f+i].
        ;; Forward iteration:  i = 0 ..< n.
        (if (i32.and
              (ref.eq (local.get $a1) (local.get $a2))
              (i32.gt_s (local.get $t) (local.get $f)))
          (then
            (local.set $i (i32.sub (local.get $n) (i32.const 1)))
            (block $done (loop $lp
              (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
              (local.set $v (call $tab_get_raw (local.get $a1)
                              (ref.i31 (i32.add (local.get $f) (local.get $i)))))
              (call $tab_set (local.get $a2)
                (ref.i31 (i32.add (local.get $t) (local.get $i)))
                (local.get $v))
              (local.set $i (i32.sub (local.get $i) (i32.const 1)))
              (br $lp))))
          (else
            (local.set $i (i32.const 0))
            (block $done2 (loop $lp2
              (br_if $done2 (i32.ge_s (local.get $i) (local.get $n)))
              (local.set $v (call $tab_get_raw (local.get $a1)
                              (ref.i31 (i32.add (local.get $f) (local.get $i)))))
              (call $tab_set (local.get $a2)
                (ref.i31 (i32.add (local.get $t) (local.get $i)))
                (local.get $v))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $lp2)))))))
    (array.new_fixed $ArgArr 1 (local.get $a2)))

  ;; table.pack(...): returns { [1] = a1, ..., [n] = an, n = nargs }.
  (func $builtin_table_pack (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $n i32) (local $i i32)
    (local $nkey (ref $LuaString))
    (local.set $t (call $tab_new))
    (local.set $n (array.len (local.get $args)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (call $tab_set (local.get $t)
        (ref.i31 (i32.add (local.get $i) (i32.const 1)))
        (call $args_at (local.get $args) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    ;; n = nargs   (key is the single-byte string "n", ASCII 110)
    (local.set $nkey (struct.new $LuaString
      (array.new_fixed $LuaArr 1 (i32.const 110))))
    (call $tab_set (local.get $t) (local.get $nkey)
      (call $make_int (i64.extend_i32_s (local.get $n))))
    (array.new_fixed $ArgArr 1 (local.get $t)))

  (func $builtin_table_unpack (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $i i32) (local $j i32) (local $nargs i32)
    (local $count i32) (local $k i32) (local $out (ref $ArgArr))
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $i (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $i (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 1)))))))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $j (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 2))))))
      (else (local.set $j (call $tab_len (local.get $t)))))
    (if (i32.lt_s (local.get $j) (local.get $i))
      (then (return (global.get $g_empty_args))))
    (local.set $count (i32.add (i32.sub (local.get $j) (local.get $i)) (i32.const 1)))
    (local.set $out (array.new $ArgArr (ref.null any) (local.get $count)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $k) (local.get $count)))
      (array.set $ArgArr (local.get $out) (local.get $k)
        (call $tab_get (local.get $t)
          (ref.i31 (i32.add (local.get $i) (local.get $k)))))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $lp)))
    (local.get $out))

  ;; --- utf8 library ---
  ;;
  ;; UTF-8 encoding helper. Writes the UTF-8 encoding of $cp at $out[$pos..]
  ;; and returns the number of bytes written. By default accepts codepoints
  ;; up to 0x10FFFF (real Unicode); with $lax non-zero, accepts up to
  ;; 0x7FFFFFFF using Lua's extended 5- and 6-byte forms. Returns -1 if
  ;; the codepoint is out of range for the chosen mode.
  (func $utf8_encode (param $out (ref $LuaArr)) (param $pos i32)
                     (param $cp i32) (param $lax i32) (result i32)
    (if (i32.lt_s (local.get $cp) (i32.const 0))
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
    (if (i32.lt_u (local.get $cp) (i32.const 0x110000))
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
    (i32.add (local.get $cont) (i32.const 1)))

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
    (local $p i32) (local $w i32)
    ;; two-pass: first count, then allocate the ArgArr and fill.
    (local $count i32) (local $idx i32)
    (local $out (ref $ArgArr))
    (local.set $bytes (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $i (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $i (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 1)))))))
    (local.set $j (local.get $i))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $j (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 2)))))))
    (if (i32.gt_u (local.get $nargs) (i32.const 3))
      (then (local.set $lax (call $lua_truthy
              (call $args_at (local.get $args) (i32.const 3))))))
    (if (i32.lt_s (local.get $i) (i32.const 0))
      (then (local.set $i (i32.add (local.get $n) (i32.add (local.get $i) (i32.const 1))))))
    (if (i32.lt_s (local.get $j) (i32.const 0))
      (then (local.set $j (i32.add (local.get $n) (i32.add (local.get $j) (i32.const 1))))))
    (if (i32.lt_s (local.get $i) (i32.const 1)) (then (local.set $i (i32.const 1))))
    (if (i32.gt_s (local.get $j) (local.get $n)) (then (local.set $j (local.get $n))))
    (if (i32.gt_s (local.get $i) (local.get $j))
      (then (return (global.get $g_empty_args))))
    ;; pass 1: count + validate
    (local.set $p (i32.sub (local.get $i) (i32.const 1)))
    (block $done1 (loop $lp1
      (br_if $done1 (i32.gt_s (i32.add (local.get $p) (i32.const 1)) (local.get $j)))
      (local.set $w (call $utf8_decode_step
        (local.get $bytes) (local.get $p) (local.get $lax)))
      (if (i32.eqz (local.get $w)) (then (throw $LuaError (ref.null any))))
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

  ;; utf8.codes iterator. Called with (s, prev_p).
  ;;   prev_p == 0 -> emit first codepoint at byte 1
  ;;   prev_p > 0  -> advance past codepoint at prev_p, emit next
  ;; Returns empty when past end. Raises on invalid sequences (strict).
  ;; (Lax flag from utf8.codes(s, lax) is currently ignored — see
  ;;  docs/stdlib.md.)
  (func $builtin_utf8_codes_iter (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $n_bytes i32)
    (local $prev i32) (local $p i32) (local $w i32)
    (local $out (ref $ArgArr))
    (local.set $bytes (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n_bytes (array.len (local.get $bytes)))
    (local.set $prev (i32.wrap_i64
      (call $as_int (call $args_at (local.get $args) (i32.const 1)))))
    (if (i32.eqz (local.get $prev))
      (then (local.set $p (i32.const 0)))
      (else
        ;; advance past the codepoint at byte $prev (1-based)
        (local.set $w (call $utf8_decode_step
          (local.get $bytes) (i32.sub (local.get $prev) (i32.const 1))
          (i32.const 0)))
        (if (i32.eqz (local.get $w))
          (then (throw $LuaError (ref.null any))))
        (local.set $p (i32.add (i32.sub (local.get $prev) (i32.const 1))
                                (local.get $w)))))
    (if (i32.ge_s (local.get $p) (local.get $n_bytes))
      (then (return (global.get $g_empty_args))))
    (local.set $w (call $utf8_decode_step
      (local.get $bytes) (local.get $p) (i32.const 0)))
    (if (i32.eqz (local.get $w))
      (then (throw $LuaError (ref.null any))))
    (local.set $out (array.new $ArgArr (ref.null any) (i32.const 2)))
    (array.set $ArgArr (local.get $out) (i32.const 0)
      (call $make_int (i64.extend_i32_s
        (i32.add (local.get $p) (i32.const 1)))))
    (array.set $ArgArr (local.get $out) (i32.const 1)
      (call $make_int (i64.extend_i32_u
        (call $utf8_assemble (local.get $bytes) (local.get $p) (local.get $w)))))
    (local.get $out))

  ;; utf8.codes(s [, lax]) — returns (iter, s, 0) for generic for.
  ;; Generic for then drives iter(s, prev) until it returns nothing.
  (func $builtin_utf8_codes (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 3
      (global.get $g_builtin_utf8_codes_iter)
      (call $args_at (local.get $args) (i32.const 0))
      (ref.i31 (i32.const 0))))

  ;; utf8.offset(s, n [, i]) — byte position of the n-th codepoint
  ;; relative to byte position i. Default i = 1 (when n >= 0) or
  ;; #s + 1 (when n < 0). Returns nil if the position is out of range.
  ;; Special case: n == 0 returns the start of the codepoint that
  ;; contains byte i.
  (func $builtin_utf8_offset (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $n_bytes i32) (local $nargs i32)
    (local $n i32) (local $i i32) (local $p i32) (local $b i32)
    (local $count i32)
    (local.set $bytes (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n_bytes (array.len (local.get $bytes)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $n (i32.wrap_i64
      (call $as_int (call $args_at (local.get $args) (i32.const 1)))))
    ;; Default i: 1 if n >= 0, else #s+1.
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $i (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 2))))))
      (else (if (i32.ge_s (local.get $n) (i32.const 0))
        (then (local.set $i (i32.const 1)))
        (else (local.set $i (i32.add (local.get $n_bytes) (i32.const 1)))))))
    ;; negative i counts from the end
    (if (i32.lt_s (local.get $i) (i32.const 0))
      (then (local.set $i (i32.add (local.get $n_bytes)
                                    (i32.add (local.get $i) (i32.const 1))))))
    ;; i must be in [1, #s+1]
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 1))
                (i32.gt_s (local.get $i) (i32.add (local.get $n_bytes) (i32.const 1))))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $p (i32.sub (local.get $i) (i32.const 1)))  ;; 0-based

    ;; n == 0: walk back from $p to the nearest non-continuation byte.
    (if (i32.eqz (local.get $n))
      (then
        (block $found (loop $bw
          (br_if $found (i32.le_s (local.get $p) (i32.const 0)))
          (local.set $b (array.get_u $LuaArr (local.get $bytes) (local.get $p)))
          (br_if $found (i32.lt_u (i32.and (local.get $b) (i32.const 0xC0))
                                   (i32.const 0x80)))
          (br_if $found (i32.ge_u (local.get $b) (i32.const 0xC0)))
          (local.set $p (i32.sub (local.get $p) (i32.const 1)))
          (br $bw)))
        (return (array.new_fixed $ArgArr 1
          (call $make_int (i64.extend_i32_s
            (i32.add (local.get $p) (i32.const 1))))))))

    ;; n > 0: starting at $p, advance (n-1) codepoints. $p must NOT be
    ;; mid-codepoint (continuation byte) unless we're at end+1.
    (if (i32.gt_s (local.get $n) (i32.const 0))
      (then
        (if (i32.lt_s (local.get $p) (local.get $n_bytes))
          (then
            (local.set $b (array.get_u $LuaArr (local.get $bytes) (local.get $p)))
            (if (i32.and (i32.ge_u (local.get $b) (i32.const 0x80))
                         (i32.lt_u (local.get $b) (i32.const 0xC0)))
              (then (throw $LuaError (ref.null any))))))
        (local.set $count (i32.sub (local.get $n) (i32.const 1)))
        (block $fdone (loop $fw
          (br_if $fdone (i32.le_s (local.get $count) (i32.const 0)))
          (if (i32.ge_s (local.get $p) (local.get $n_bytes))
            (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
          ;; advance one codepoint = 1 + count of trailing continuation bytes
          (local.set $p (i32.add (local.get $p) (i32.const 1)))
          (block $skip_done (loop $skip
            (br_if $skip_done (i32.ge_s (local.get $p) (local.get $n_bytes)))
            (local.set $b (array.get_u $LuaArr (local.get $bytes) (local.get $p)))
            (br_if $skip_done (i32.lt_u (i32.and (local.get $b) (i32.const 0xC0))
                                         (i32.const 0x80)))
            (br_if $skip_done (i32.ge_u (local.get $b) (i32.const 0xC0)))
            (local.set $p (i32.add (local.get $p) (i32.const 1)))
            (br $skip)))
          (local.set $count (i32.sub (local.get $count) (i32.const 1)))
          (br $fw)))
        (if (i32.gt_s (local.get $p) (local.get $n_bytes))
          (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
        (return (array.new_fixed $ArgArr 1
          (call $make_int (i64.extend_i32_s
            (i32.add (local.get $p) (i32.const 1))))))))

    ;; n < 0: step back (-n) codepoints from $p.
    (local.set $count (i32.sub (i32.const 0) (local.get $n)))
    (block $bdone (loop $bw2
      (br_if $bdone (i32.le_s (local.get $count) (i32.const 0)))
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (if (i32.lt_s (local.get $p) (i32.const 0))
        (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
      ;; back up over continuation bytes to the lead byte
      (block $lead_done (loop $back
        (br_if $lead_done (i32.le_s (local.get $p) (i32.const 0)))
        (local.set $b (array.get_u $LuaArr (local.get $bytes) (local.get $p)))
        (br_if $lead_done (i32.lt_u (i32.and (local.get $b) (i32.const 0xC0))
                                     (i32.const 0x80)))
        (br_if $lead_done (i32.ge_u (local.get $b) (i32.const 0xC0)))
        (local.set $p (i32.sub (local.get $p) (i32.const 1)))
        (br $back)))
      (local.set $count (i32.sub (local.get $count) (i32.const 1)))
      (br $bw2)))
    (array.new_fixed $ArgArr 1
      (call $make_int (i64.extend_i32_s
        (i32.add (local.get $p) (i32.const 1))))))

  ;; utf8.len(s [, i [, j [, lax]]]) — count codepoints starting in [i, j].
  ;; Returns the count, OR (nil, errpos) on the first invalid byte.
  (func $builtin_utf8_len (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $n i32) (local $nargs i32)
    (local $i i32) (local $j i32) (local $lax i32)
    (local $p i32) (local $w i32) (local $count i64)
    (local $out (ref $ArgArr))
    (local.set $bytes (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $i (i32.const 1))
    (local.set $j (i32.const -1))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $i (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 1)))))))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $j (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 2)))))))
    (if (i32.gt_u (local.get $nargs) (i32.const 3))
      (then (local.set $lax (call $lua_truthy
              (call $args_at (local.get $args) (i32.const 3))))))
    ;; negative-index normalisation, then 1-based clamp
    (if (i32.lt_s (local.get $i) (i32.const 0))
      (then (local.set $i (i32.add (local.get $n) (i32.add (local.get $i) (i32.const 1))))))
    (if (i32.lt_s (local.get $j) (i32.const 0))
      (then (local.set $j (i32.add (local.get $n) (i32.add (local.get $j) (i32.const 1))))))
    (if (i32.lt_s (local.get $i) (i32.const 1)) (then (local.set $i (i32.const 1))))
    (if (i32.gt_s (local.get $j) (local.get $n)) (then (local.set $j (local.get $n))))
    (local.set $p (i32.sub (local.get $i) (i32.const 1)))   ;; 0-based
    (block $done (loop $lp
      (br_if $done (i32.gt_s (i32.add (local.get $p) (i32.const 1)) (local.get $j)))
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
    (local.set $buf (array.new $LuaArr (i32.const 0)
                      (i32.mul (local.get $n) (i32.const 4))))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $cp (call $as_int (call $args_at (local.get $args) (local.get $i))))
      ;; reject out-of-range before truncating to i32
      (if (i32.or (i64.lt_s (local.get $cp) (i64.const 0))
                  (i64.gt_s (local.get $cp) (i64.const 0x10FFFF)))
        (then (throw $LuaError (ref.null any))))
      (local.set $w (call $utf8_encode
        (local.get $buf) (local.get $pos)
        (i32.wrap_i64 (local.get $cp)) (i32.const 0)))
      (if (i32.lt_s (local.get $w) (i32.const 0))
        (then (throw $LuaError (ref.null any))))
      (local.set $pos (i32.add (local.get $pos) (local.get $w)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    ;; trim to actual length
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $pos)))
    (array.copy $LuaArr $LuaArr
      (local.get $out) (i32.const 0)
      (local.get $buf) (i32.const 0) (local.get $pos))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out))))

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
                        (else
                          ;; Unrecognized class letter — literal compare.
                          (return (i32.eq (local.get $byte) (local.get $letter)))))))))))))))))))))))
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
    (local $saved i32)
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
        ;; idx is the open capture to close.
        (local.set $saved (i32.const -1))
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
        ;; rewind the close
        (array.set $CapArr (local.get $caps)
          (i32.add (i32.mul (local.get $idx) (i32.const 2)) (i32.const 1))
          (local.get $saved))
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
    (struct.new $LuaString (local.get $bytes)))

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
    (local.set $sub (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $pat (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $n_sub (array.len (local.get $sub)))
    (local.set $n_pat (array.len (local.get $pat)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $init (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $init (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 2)))))))
    (if (i32.gt_u (local.get $nargs) (i32.const 3))
      (then (local.set $plain (call $lua_truthy
              (call $args_at (local.get $args) (i32.const 3))))))
    (if (i32.lt_s (local.get $init) (i32.const 0))
      (then (local.set $init (i32.add (local.get $n_sub)
                                       (i32.add (local.get $init) (i32.const 1))))))
    (if (i32.lt_s (local.get $init) (i32.const 1))
      (then (local.set $init (i32.const 1))))
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
    (local.set $start_ppos (i32.const 0))
    (if (i32.and (i32.gt_s (local.get $n_pat) (i32.const 0))
                 (i32.eq (array.get_u $LuaArr (local.get $pat) (i32.const 0))
                         (i32.const 94)))   ;; '^'
      (then (local.set $anchored (i32.const 1))
            (local.set $start_ppos (i32.const 1))))
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
    (local.set $sub (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $pat (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $n_sub (array.len (local.get $sub)))
    (local.set $n_pat (array.len (local.get $pat)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $init (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $init (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 2)))))))
    (if (i32.lt_s (local.get $init) (i32.const 0))
      (then (local.set $init (i32.add (local.get $n_sub)
                                       (i32.add (local.get $init) (i32.const 1))))))
    (if (i32.lt_s (local.get $init) (i32.const 1))
      (then (local.set $init (i32.const 1))))
    (if (i32.gt_s (local.get $init) (i32.add (local.get $n_sub) (i32.const 1)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $start_ppos (i32.const 0))
    (if (i32.and (i32.gt_s (local.get $n_pat) (i32.const 0))
                 (i32.eq (array.get_u $LuaArr (local.get $pat) (i32.const 0))
                         (i32.const 94)))
      (then (local.set $anchored (i32.const 1))
            (local.set $start_ppos (i32.const 1))))
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
                (struct.new $LuaString (local.get $whole))))))
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

  ;; string.gmatch iterator step. Upvalues: (s, pat, cursor_box).
  (func $builtin_string_gmatch_iter (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $upvals (ref $UpvalArr))
    (local $sub (ref $LuaArr)) (local $pat (ref $LuaArr))
    (local $n_sub i32) (local $n_pat i32)
    (local $cursor i32) (local $sp i32) (local $end i32) (local $ncaps i32)
    (local $caps (ref $CapArr)) (local $out (ref $ArgArr)) (local $i i32)
    (local $whole (ref $LuaArr)) (local $start_ppos i32)
    (local.set $upvals (struct.get $LuaClosure $upvals (local.get $self)))
    (local.set $sub (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString)
        (struct.get $Box $v
          (array.get $UpvalArr (local.get $upvals) (i32.const 0))))))
    (local.set $pat (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString)
        (struct.get $Box $v
          (array.get $UpvalArr (local.get $upvals) (i32.const 1))))))
    (local.set $cursor (i32.wrap_i64 (call $as_int
      (struct.get $Box $v
        (array.get $UpvalArr (local.get $upvals) (i32.const 2))))))
    (local.set $n_sub (array.len (local.get $sub)))
    (local.set $n_pat (array.len (local.get $pat)))
    ;; gmatch does not honour '^' as an anchor (the iteration would
    ;; produce at most one match). Treat a leading '^' as a literal.
    (local.set $start_ppos (i32.const 0))
    (local.set $sp (local.get $cursor))
    (local.set $caps (array.new $CapArr (i32.const 0) (i32.const 64)))
    (block $search_done (loop $search
      (br_if $search_done (i32.gt_s (local.get $sp) (local.get $n_sub)))
      (call $match_pat
        (local.get $sub) (local.get $sp)
        (local.get $pat) (local.get $start_ppos)
        (local.get $caps) (i32.const 0))
      (local.set $ncaps)
      (local.set $end)
      (if (i32.ge_s (local.get $end) (i32.const 0))
        (then
          ;; Empty-match progress guard.
          (if (i32.eq (local.get $end) (local.get $sp))
            (then (local.set $cursor (i32.add (local.get $end) (i32.const 1))))
            (else (local.set $cursor (local.get $end))))
          (struct.set $Box $v
            (array.get $UpvalArr (local.get $upvals) (i32.const 2))
            (call $make_int (i64.extend_i32_s (local.get $cursor))))
          (if (i32.eqz (local.get $ncaps))
            (then
              (local.set $whole (array.new $LuaArr (i32.const 0)
                (i32.sub (local.get $end) (local.get $sp))))
              (array.copy $LuaArr $LuaArr
                (local.get $whole) (i32.const 0)
                (local.get $sub) (local.get $sp)
                (i32.sub (local.get $end) (local.get $sp)))
              (return (array.new_fixed $ArgArr 1
                (struct.new $LuaString (local.get $whole))))))
          (local.set $out (array.new $ArgArr (ref.null any) (local.get $ncaps)))
          (local.set $i (i32.const 0))
          (block $cdone (loop $cp
            (br_if $cdone (i32.ge_s (local.get $i) (local.get $ncaps)))
            (array.set $ArgArr (local.get $out) (local.get $i)
              (call $cap_to_value (local.get $sub) (local.get $caps) (local.get $i)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp)))
          (return (local.get $out))))
      (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
      (br $search)))
    (global.get $g_empty_args))

  ;; string.gmatch(s, pat [, init]) — returns an iterator closure with
  ;; three upvalues (s, pat, cursor). Generic for drives it to
  ;; completion.
  (func $builtin_string_gmatch (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $init i32) (local $nargs i32)
    (local.set $nargs (array.len (local.get $args)))
    (local.set $init (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $init (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 2)))))))
    (if (i32.lt_s (local.get $init) (i32.const 1))
      (then (local.set $init (i32.const 1))))
    (array.new_fixed $ArgArr 1
      (struct.new $LuaClosure
        (ref.func $builtin_string_gmatch_iter)
        (array.new_fixed $UpvalArr 3
          (struct.new $Box (call $args_at (local.get $args) (i32.const 0)))
          (struct.new $Box (call $args_at (local.get $args) (i32.const 1)))
          (struct.new $Box (call $make_int
            (i64.extend_i32_s (i32.sub (local.get $init) (i32.const 1)))))))))

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

  ;; Convert the builder into a (ref $LuaString), trimming to exact length.
  (func $builder_finish (param $b (ref $Builder)) (result (ref $LuaString))
    (local $out (ref $LuaArr)) (local $n i32)
    (local.set $n (struct.get $Builder $len (local.get $b)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (array.copy $LuaArr $LuaArr
      (local.get $out) (i32.const 0)
      (struct.get $Builder $arr (local.get $b)) (i32.const 0)
      (local.get $n))
    (struct.new $LuaString (local.get $out)))

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
                        (else (throw $LuaError (ref.null any)))))
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
        (throw $LuaError (ref.null any))))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then
        (local.set $bytes (struct.get $LuaString $bytes
          (ref.cast (ref $LuaString) (local.get $v))))
        (call $builder_append (local.get $b) (local.get $bytes)
          (i32.const 0) (array.len (local.get $bytes)))
        (return)))
    (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
      (then
        (local.set $bytes (struct.get $LuaString $bytes
          (call $lua_tostring (local.get $v))))
        (call $builder_append (local.get $b) (local.get $bytes)
          (i32.const 0) (array.len (local.get $bytes)))
        (return)))
    (throw $LuaError (ref.null any)))

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
        (local.set $key (struct.new $LuaString (local.get $bytes))))
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
          (struct.new $LuaString (local.get $bytes))))
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
    (local $last_end i32) (local $b (ref $Builder))
    (local.set $sub (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $pat (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 1)))))
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
              (call $as_int (call $args_at (local.get $args) (i32.const 3)))))))
    ;; Classify repl. Reject unsupported types early.
    (if (ref.test (ref $LuaString) (local.get $repl_v))
      (then (local.set $repl_kind (i32.const 0))
            (local.set $repl_bytes (struct.get $LuaString $bytes
              (ref.cast (ref $LuaString) (local.get $repl_v)))))
      (else (if (ref.test (ref $LuaTable) (local.get $repl_v))
        (then (local.set $repl_kind (i32.const 1))
              (local.set $repl_bytes (array.new $LuaArr (i32.const 0) (i32.const 0))))
        (else (if (ref.test (ref $LuaClosure) (local.get $repl_v))
          (then (local.set $repl_kind (i32.const 2))
                (local.set $repl_bytes (array.new $LuaArr (i32.const 0) (i32.const 0))))
          (else (throw $LuaError (ref.null any))))))))
    (local.set $start_ppos (i32.const 0))
    (if (i32.and (i32.gt_s (local.get $n_pat) (i32.const 0))
                 (i32.eq (array.get_u $LuaArr (local.get $pat) (i32.const 0))
                         (i32.const 94)))
      (then (local.set $anchored (i32.const 1))
            (local.set $start_ppos (i32.const 1))))
    (local.set $b (call $builder_new))
    (local.set $caps (array.new $CapArr (i32.const 0) (i32.const 64)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $count) (local.get $limit)))
      (br_if $done (i32.gt_s (local.get $sp) (local.get $n_sub)))
      (call $match_pat
        (local.get $sub) (local.get $sp)
        (local.get $pat) (local.get $start_ppos)
        (local.get $caps) (i32.const 0))
      (local.set $ncaps)
      (local.set $end)
      (if (i32.ge_s (local.get $end) (i32.const 0))
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
          (br_if $done (local.get $anchored))
          (br $lp)))
      (br_if $done (local.get $anchored))
      (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
      (br $lp)))
    (call $builder_append (local.get $b) (local.get $sub)
      (local.get $last_end)
      (i32.sub (local.get $n_sub) (local.get $last_end)))
    (array.new_fixed $ArgArr 2
      (call $builder_finish (local.get $b))
      (call $make_int (i64.extend_i32_s (local.get $count)))))

  ;; --- string library ---
  (func $builtin_string_len (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $lua_len
      (call $args_at (local.get $args) (i32.const 0)))))

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
  (func $builtin_string_char (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $b i64)
    (local $out (ref $LuaArr))
    (local.set $n (array.len (local.get $args)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (call $as_int (call $args_at (local.get $args) (local.get $i))))
      (if (i32.or (i64.lt_s (local.get $b) (i64.const 0))
                  (i64.gt_s (local.get $b) (i64.const 255)))
        (then (throw $LuaError (ref.null any))))
      (array.set $LuaArr (local.get $out) (local.get $i)
        (i32.wrap_i64 (local.get $b)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out))))

  ;; string.byte(s [, i [, j]]) — returns the byte values of s[i..j]
  ;; as multiple results. Defaults: i = 1, j = i. Negative indices
  ;; count from the end. Empty range returns no values.
  (func $builtin_string_byte (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $n i32)
    (local $i i32) (local $j i32) (local $count i32) (local $k i32)
    (local $nargs i32) (local $out (ref $ArgArr))
    (local.set $bytes (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $i (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $i (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 1)))))))
    (local.set $j (local.get $i))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $j (i32.wrap_i64
              (call $as_int (call $args_at (local.get $args) (i32.const 2)))))))
    ;; negative index normalisation (relative to end of string)
    (if (i32.lt_s (local.get $i) (i32.const 0))
      (then (local.set $i (i32.add (local.get $n) (i32.add (local.get $i) (i32.const 1))))))
    (if (i32.lt_s (local.get $j) (i32.const 0))
      (then (local.set $j (i32.add (local.get $n) (i32.add (local.get $j) (i32.const 1))))))
    ;; clamp to [1, n]
    (if (i32.lt_s (local.get $i) (i32.const 1)) (then (local.set $i (i32.const 1))))
    (if (i32.gt_s (local.get $j) (local.get $n)) (then (local.set $j (local.get $n))))
    (if (i32.gt_s (local.get $i) (local.get $j))
      (then (return (global.get $g_empty_args))))
    (local.set $count (i32.add (i32.sub (local.get $j) (local.get $i)) (i32.const 1)))
    (local.set $out (array.new $ArgArr (ref.null any) (local.get $count)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $k) (local.get $count)))
      (array.set $ArgArr (local.get $out) (local.get $k)
        (call $make_int (i64.extend_i32_u
          (array.get_u $LuaArr (local.get $bytes)
            (i32.sub (i32.add (local.get $i) (local.get $k)) (i32.const 1))))))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $lp)))
    (local.get $out))

  ;; string.rep(s, n [, sep]) — n copies of s, joined by sep.
  ;; n <= 0 returns "". sep defaults to "". Result length is
  ;; n*len(s) + max(0, n-1)*len(sep), allocated once.
  (func $builtin_string_rep (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $sb (ref $LuaArr)) (local $pb (ref $LuaArr))
    (local $n i32) (local $slen i32) (local $plen i32)
    (local $total i32) (local $i i32) (local $pos i32)
    (local $out (ref $LuaArr))
    (local.set $sb (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1)))))
    ;; optional sep (default empty)
    (local.set $pb (array.new $LuaArr (i32.const 0) (i32.const 0)))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 2))
      (then (local.set $pb (struct.get $LuaString $bytes
              (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 2)))))))
    (local.set $slen (array.len (local.get $sb)))
    (local.set $plen (array.len (local.get $pb)))
    (if (i32.le_s (local.get $n) (i32.const 0))
      (then (return (array.new_fixed $ArgArr 1
              (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0)))))))
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
    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out))))

  ;; string.reverse(s) — byte-reversed string.
  (func $builtin_string_reverse (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $out (ref $LuaArr))
    (local $n i32) (local $i i32)
    (local.set $bytes (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (array.set $LuaArr (local.get $out) (local.get $i)
        (array.get_u $LuaArr (local.get $bytes)
          (i32.sub (i32.sub (local.get $n) (i32.const 1)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out))))

  ;; string.upper(s) — ASCII a-z -> A-Z, other bytes unchanged.
  (func $builtin_string_upper (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString
      (call $str_case_map
        (struct.get $LuaString $bytes
          (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0))))
        (i32.const 97) (i32.const 122) (i32.const -32)))))

  ;; string.lower(s) — ASCII A-Z -> a-z, other bytes unchanged.
  (func $builtin_string_lower (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString
      (call $str_case_map
        (struct.get $LuaString $bytes
          (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0))))
        (i32.const 65) (i32.const 90) (i32.const 32)))))

  ;; string.sub(s, i, [j])
  (func $builtin_string_sub (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $s (ref $LuaString)) (local $bytes (ref $LuaArr))
    (local $n i32) (local $i i32) (local $j i32) (local $len i32)
    (local $out (ref $LuaArr))
    (local.set $s (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $bytes (struct.get $LuaString $bytes (local.get $s)))
    (local.set $n (array.len (local.get $bytes)))
    (local.set $i (i32.wrap_i64 (call $as_int (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $j (local.get $n))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 2))
      (then
        (local.set $j (i32.wrap_i64
          (call $as_int (call $args_at (local.get $args) (i32.const 2)))))))
    (if (i32.lt_s (local.get $i) (i32.const 0))
      (then (local.set $i (i32.add (local.get $n) (i32.add (local.get $i) (i32.const 1))))))
    (if (i32.lt_s (local.get $j) (i32.const 0))
      (then (local.set $j (i32.add (local.get $n) (i32.add (local.get $j) (i32.const 1))))))
    (if (i32.lt_s (local.get $i) (i32.const 1)) (then (local.set $i (i32.const 1))))
    (if (i32.gt_s (local.get $j) (local.get $n)) (then (local.set $j (local.get $n))))
    (if (i32.gt_s (local.get $i) (local.get $j))
      (then (return (array.new_fixed $ArgArr 1
        (struct.new $LuaString (array.new $LuaArr (i32.const 0) (i32.const 0)))))))
    (local.set $len (i32.add (i32.sub (local.get $j) (local.get $i)) (i32.const 1)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $len)))
    (array.copy $LuaArr $LuaArr
      (local.get $out)   (i32.const 0)
      (local.get $bytes) (i32.sub (local.get $i) (i32.const 1))
      (local.get $len))
    (array.new_fixed $ArgArr 1 (struct.new $LuaString (local.get $out))))

  ;; Builds a $LuaString from the first $n bytes of $fmt_buf.
  (func $fmt_buf_to_str (param $n i32) (result (ref $LuaString))
    (local $out (ref $LuaArr))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)
      (ref.as_non_null (global.get $fmt_buf)) (i32.const 0) (local.get $n))
    (struct.new $LuaString (local.get $out)))

  ;; string.format(fmt, ...) — supports %s %d %x %g %f %e with optional .N
  ;; precision, plus %%. No width/flags.
  ;; string.format(fmt, ...) — walks fmt, copying literal runs and
  ;; delegating each %... directive to the host's fmt_spec helper.
  ;; The host handles flags/width/precision and all the conversion
  ;; specifiers (s d i o u x X c q e E f F g G a A %).
  (func $builtin_string_format (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $fmt (ref $LuaArr)) (local $n i32) (local $i i32) (local $j i32)
    (local $acc anyref) (local $b i32) (local $piece (ref $LuaArr))
    (local $arg_idx i32) (local $arg anyref) (local $written i32)
    (local $spec (ref $LuaArr))
    (local.set $fmt (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $fmt)))
    (local.set $acc (ref.as_non_null (global.get $g_empty_str)))
    (local.set $arg_idx (i32.const 1))
    (block $done (loop $main
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $i)))
      (if (i32.ne (local.get $b) (i32.const 37))     ;; not '%' -> literal run
        (then
          (local.set $j (i32.add (local.get $i) (i32.const 1)))
          (block $rdone (loop $rloop
            (br_if $rdone (i32.ge_s (local.get $j) (local.get $n)))
            (br_if $rdone (i32.eq (array.get_u $LuaArr (local.get $fmt) (local.get $j))
                                   (i32.const 37)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $rloop)))
          (local.set $piece (array.new $LuaArr (i32.const 0)
                              (i32.sub (local.get $j) (local.get $i))))
          (array.copy $LuaArr $LuaArr (local.get $piece) (i32.const 0)
            (local.get $fmt) (local.get $i)
            (i32.sub (local.get $j) (local.get $i)))
          (local.set $acc (call $lua_concat (local.get $acc)
                            (struct.new $LuaString (local.get $piece))))
          (local.set $i (local.get $j))
          (br $main)))
      ;; here $b == '%'.  Scan ahead to find the conversion character.
      ;; Valid char set: flags [-+ #0'], digits, '.', length modifiers
      ;; (we ignore those), then a single alphabetic conversion char,
      ;; OR another '%' for the literal escape.
      (local.set $j (i32.add (local.get $i) (i32.const 1)))
      (if (i32.ge_s (local.get $j) (local.get $n)) (then (br $done)))
      (block $sdone (loop $sloop
        (if (i32.ge_s (local.get $j) (local.get $n)) (then (br $sdone)))
        (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $j)))
        ;; Stop on '%' (literal escape) or on an alphabetic char.
        (br_if $sdone (i32.eq (local.get $b) (i32.const 37)))
        (br_if $sdone (i32.and
          (i32.or
            (i32.and (i32.ge_u (local.get $b) (i32.const 65))
                     (i32.le_u (local.get $b) (i32.const 90)))    ;; A-Z
            (i32.and (i32.ge_u (local.get $b) (i32.const 97))
                     (i32.le_u (local.get $b) (i32.const 122))))  ;; a-z
          (i32.const 1)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $sloop)))
      (if (i32.ge_s (local.get $j) (local.get $n)) (then (br $done)))
      ;; Build a LuaString containing %...conv (inclusive).
      (local.set $spec (array.new $LuaArr (i32.const 0)
                          (i32.add (i32.sub (local.get $j) (local.get $i))
                                    (i32.const 1))))
      (array.copy $LuaArr $LuaArr (local.get $spec) (i32.const 0)
        (local.get $fmt) (local.get $i)
        (i32.add (i32.sub (local.get $j) (local.get $i)) (i32.const 1)))
      ;; %% literal: no arg consumed
      (if (i32.eq (array.get_u $LuaArr (local.get $fmt) (local.get $j))
                  (i32.const 37))
        (then
          (local.set $arg (ref.null any)))
        (else
          (local.set $arg (call $args_at (local.get $args) (local.get $arg_idx)))
          (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
          ;; For %s and %q, pre-tostring so __tostring is honoured.
          (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $j)))
          (if (i32.or (i32.eq (local.get $b) (i32.const 115))   ;; 's'
                      (i32.eq (local.get $b) (i32.const 113)))  ;; 'q'
            (then (local.set $arg (call $lua_tostring (local.get $arg)))))))
      (local.set $written (call $host_fmt_spec
        (struct.new $LuaString (local.get $spec))
        (local.get $arg)))
      (local.set $acc (call $lua_concat (local.get $acc)
                        (call $fmt_buf_to_str (local.get $written))))
      (local.set $i (i32.add (local.get $j) (i32.const 1)))
      (br $main)))
    (array.new_fixed $ArgArr 1 (call $lua_tostring (local.get $acc))))

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
  ;;   - c without [N], or c0
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
          (then (throw $LuaError (ref.null any))))
        (if (i32.gt_s (local.get $n) (i32.const 16))
          (then (throw $LuaError (ref.null any))))
        (return (local.get $n) (local.get $newpp))))
    ;; c: required [N] >= 0. (c0 is allowed and means "zero bytes".)
    (if (i32.eq (local.get $opt) (i32.const 99))                 ;; 'c'
      (then
        (call $pack_n_suffix (local.get $bytes) (local.get $ppos)
                             (i32.const -1))
        (local.set $newpp) (local.set $n)
        (if (i32.lt_s (local.get $n) (i32.const 0))
          (then (throw $LuaError (ref.null any))))
        (return (local.get $n) (local.get $newpp))))
    ;; Unknown letter.
    (throw $LuaError (ref.null any)))

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
      (then (throw $LuaError (ref.null any))))
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
    (local $i i32) (local $b i32)
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (i32.and
        (i32.wrap_i64
          (i64.shr_u (local.get $val)
                     (i64.extend_i32_u
                       (i32.mul (local.get $i) (i32.const 8)))))
        (i32.const 0xff)))
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
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
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
      (ref.cast (ref $LuaString)
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
            (then (throw $LuaError (ref.null any))))
          (if (i32.gt_s (local.get $n) (i32.const 16))
            (then (throw $LuaError (ref.null any))))
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
            (then (throw $LuaError (ref.null any))))
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
        (then (throw $LuaError (ref.null any))))
      (if (i32.eq (local.get $c) (i32.const 122))                ;; 'z'
        (then (throw $LuaError (ref.null any))))
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

  ;; string.pack(fmt, v1, v2, ...) — milestone 21 step 2: unsigned ints
  ;; (B H I[N] J L T), x padding, !N alignment, Xop, < > = endianness.
  ;; Signed ints / floats / c / s / z land in later steps; this dispatch
  ;; raises on them.
  (func $builtin_string_pack (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr))
    (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $len i32) (local $ppos i32)
    (local $c i32) (local $endian_le i32) (local $max_align i32)
    (local $sz i32) (local $n i32) (local $newpp i32)
    (local $arg_idx i32) (local $val i64) (local $pad i32)
    (local $b (ref $Builder)) (local $bbuf (ref $LuaArr)) (local $blen i32)
    (local.set $endian_le (i32.const 1))
    (local.set $max_align (i32.const 1))
    (local.set $arg_idx (i32.const 1))
    (local.set $b (call $builder_new))
    (local.set $bytes (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString)
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
            (then (throw $LuaError (ref.null any))))
          (if (i32.gt_s (local.get $n) (i32.const 16))
            (then (throw $LuaError (ref.null any))))
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
            (then (throw $LuaError (ref.null any))))
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
      ;; Variable-length and not-yet-implemented options raise.
      (if (i32.or (i32.eq (local.get $c) (i32.const 115))        ;; 's'
                  (i32.eq (local.get $c) (i32.const 122)))       ;; 'z'
        (then (throw $LuaError (ref.null any))))
      (if (i32.eq (local.get $c) (i32.const 99))                 ;; 'c'
        (then (throw $LuaError (ref.null any))))
      (if (i32.or (i32.eq (local.get $c) (i32.const 102))        ;; 'f'
                  (i32.or (i32.eq (local.get $c) (i32.const 100))   ;; 'd'
                          (i32.eq (local.get $c) (i32.const 110)))) ;; 'n'
        (then (throw $LuaError (ref.null any))))
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
      (local.set $val (call $as_int (call $args_at (local.get $args)
                                                    (local.get $arg_idx))))
      (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
      (if (call $pack_opt_is_signed (local.get $c))
        (then
          (if (i32.eqz (call $pack_fits_signed (local.get $val) (local.get $sz)))
            (then (throw $LuaError (ref.null any)))))
        (else
          (if (i32.eqz (call $pack_fits_unsigned (local.get $val) (local.get $sz)))
            (then (throw $LuaError (ref.null any))))))
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

  ;; string.unpack(fmt, s [, pos]) — same coverage as $builtin_string_pack
  ;; (step 2: unsigned ints, x, !N, Xop, < > =). Returns values…, pos
  ;; (one-past-last-consumed byte, 1-based).
  (func $builtin_string_unpack (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr))
    (result (ref $ArgArr))
    (local $bytes (ref $LuaArr)) (local $len i32) (local $ppos i32)
    (local $c i32) (local $endian_le i32) (local $max_align i32)
    (local $sz i32) (local $n i32) (local $newpp i32)
    (local $subj (ref $LuaArr)) (local $subj_len i32) (local $offset i32)
    (local $out (ref $ArgArr)) (local $out_idx i32) (local $nval i32)
    (local $val i64)
    (local.set $endian_le (i32.const 1))
    (local.set $max_align (i32.const 1))
    (local.set $bytes (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString)
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
            (call $as_int (call $args_at (local.get $args) (i32.const 2))))
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
            (then (throw $LuaError (ref.null any))))
          (if (i32.gt_s (local.get $n) (i32.const 16))
            (then (throw $LuaError (ref.null any))))
          (local.set $max_align (local.get $n))
          (local.set $ppos (local.get $newpp))
          (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 120))                ;; 'x'
        (then (local.set $offset (i32.add (local.get $offset) (i32.const 1)))
              (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 88))                 ;; 'X'
        (then
          (if (i32.ge_u (local.get $ppos) (local.get $len))
            (then (throw $LuaError (ref.null any))))
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
      (if (i32.or (i32.eq (local.get $c) (i32.const 115))
                  (i32.eq (local.get $c) (i32.const 122)))
        (then (throw $LuaError (ref.null any))))
      (if (i32.eq (local.get $c) (i32.const 99))
        (then (throw $LuaError (ref.null any))))
      (if (i32.or (i32.eq (local.get $c) (i32.const 102))
                  (i32.or (i32.eq (local.get $c) (i32.const 100))
                          (i32.eq (local.get $c) (i32.const 110))))
        (then (throw $LuaError (ref.null any))))
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
        (then (throw $LuaError (ref.null any))))
      (local.set $val (call $pack_read_int (local.get $subj)
                            (local.get $offset) (local.get $sz)
                            (local.get $endian_le)))
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

  ;; bytes_of_lit: looks up a built-in literal name (`number`, `string`, etc.)
  ;; by index into the type-name slab. Indices into the slab:
  ;;   0  "number"     (6 bytes)
  ;;   1  "string"     (6 bytes)
  ;;   2  "table"      (5 bytes)
  ;;   3  "function"   (8 bytes)
  ;;   7  "boolean"    (7 bytes, overlaps the prefix region)
  ;;   19 "nil"        (3 bytes)
  ;;
  ;; The slab is the same `$str_data` segment used by $lua_tostring. We
  ;; carefully reserve names at known offsets in codegen_module.
  (func $bytes_of_lit (param $idx i32) (result (ref $LuaArr))
    (block $r (result (ref $LuaArr))
      (if (i32.eq (local.get $idx) (i32.const 0))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 19) (i32.const 6)))))
      (if (i32.eq (local.get $idx) (i32.const 1))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 25) (i32.const 6)))))
      (if (i32.eq (local.get $idx) (i32.const 2))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 31) (i32.const 5)))))
      (if (i32.eq (local.get $idx) (i32.const 3))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 36) (i32.const 8)))))
      (if (i32.eq (local.get $idx) (i32.const 7))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 44) (i32.const 7)))))
      (array.new_data $LuaArr $str_data (i32.const 0) (i32.const 3))))


  ;; --- exported decoders for the JS host ---
  (func (export "lua_tag") (param $v anyref) (result i32)
    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
    (if (ref.test (ref $LuaBool)   (local.get $v)) (then (return (i32.const 1))))
    (if (call $is_int  (local.get $v))             (then (return (i32.const 2))))
    (if (call $is_float (local.get $v))            (then (return (i32.const 3))))
    (if (ref.test (ref $LuaString) (local.get $v)) (then (return (i32.const 4))))
    (if (ref.test (ref $LuaClosure) (local.get $v)) (then (return (i32.const 5))))
    (if (ref.test (ref $LuaTable) (local.get $v)) (then (return (i32.const 6))))
    (i32.const 99))
  (func (export "lua_get_bool") (param $v anyref) (result i32)
    (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v))))
  (func (export "lua_get_int") (param $v anyref) (result i64)
    (call $as_int (local.get $v)))
  (func (export "lua_get_float") (param $v anyref) (result f64)
    (call $as_float (local.get $v)))
  (func (export "lua_str_len") (param $v anyref) (result i32)
    (array.len (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $v)))))
  (func (export "lua_str_byte") (param $v anyref) (param $i i32) (result i32)
    (array.get_u $LuaArr
      (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $v)))
      (local.get $i)))
  ;; Host-callable constructors so JS can build int/float values from
  ;; parsed strings (used by tonumber).
  (func (export "lua_make_int") (param $v i64) (result anyref)
    (call $make_int (local.get $v)))
  (func (export "lua_make_float") (param $v f64) (result anyref)
    (call $make_float (local.get $v)))
  ;; JS-side writer for the format scratch buffer.
  (func (export "fmt_buf_set") (param $i i32) (param $b i32)
    (array.set $LuaArr (ref.as_non_null (global.get $fmt_buf))
      (local.get $i) (local.get $b)))
