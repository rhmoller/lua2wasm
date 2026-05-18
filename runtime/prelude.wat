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
  ;; host_read: read next line from stdin into $fmt_buf and return the
  ;; length; returns -1 on EOF.
  (import "host" "read" (func $host_read (result i32)))
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

  (func $lua_add (param $a anyref) (param $b anyref) (result anyref)
    (local $mm anyref)
    (if (i32.and (call $is_numlike (local.get $a)) (call $is_numlike (local.get $b)))
      (then
        (if (result anyref)
          (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
          (then (return (call $make_int (i64.add (call $as_int (local.get $a))
                                                  (call $as_int (local.get $b))))))
          (else (return (call $make_float (f64.add (call $as_float (local.get $a))
                                                    (call $as_float (local.get $b)))))))))
    ;; metamethod path
    (local.set $mm (call $get_metamethod (local.get $a) (ref.as_non_null (global.get $g_mkey_add))))
    (if (ref.is_null (local.get $mm))
      (then (local.set $mm (call $get_metamethod (local.get $b) (ref.as_non_null (global.get $g_mkey_add))))))
    (if (ref.is_null (local.get $mm))
      (then (throw $LuaError (ref.null any))))
    (call $args_first (call $lua_call
      (ref.cast (ref $LuaClosure) (local.get $mm))
      (array.new_fixed $ArgArr 2 (local.get $a) (local.get $b)))))

  (func $lua_sub (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (call $make_int (i64.sub (call $as_int (local.get $a))
                                     (call $as_int (local.get $b)))))
      (else (call $make_float (f64.sub (call $as_float (local.get $a))
                                       (call $as_float (local.get $b)))))))

  (func $lua_mul (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (call $make_int (i64.mul (call $as_int (local.get $a))
                                     (call $as_int (local.get $b)))))
      (else (call $make_float (f64.mul (call $as_float (local.get $a))
                                       (call $as_float (local.get $b)))))))

  ;; / always yields float (Lua 5.4/5.5)
  (func $lua_div (param $a anyref) (param $b anyref) (result anyref)
    (call $make_float (f64.div (call $as_float (local.get $a))
                               (call $as_float (local.get $b)))))

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
    (call $make_float (f64.floor
      (f64.div (call $as_float (local.get $a))
               (call $as_float (local.get $b))))))

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
    (local.set $af (call $as_float (local.get $a)))
    (local.set $bf (call $as_float (local.get $b)))
    (call $make_float
      (f64.sub (local.get $af)
               (f64.mul (f64.floor (f64.div (local.get $af) (local.get $bf)))
                        (local.get $bf)))))

  ;; `^` is always-float per Lua spec. Routes to host pow so that
  ;; non-integer exponents (2^0.5), negative exponents (2^-1), and
  ;; mixed-sign edge cases (NaN, inf, 0^0) all match IEEE-754 pow.
  (func $lua_pow (param $a anyref) (param $b anyref) (result anyref)
    (call $make_float
      (call $host_math2 (i32.const 1)
        (call $as_float (local.get $a))
        (call $as_float (local.get $b)))))

  (func $lua_neg (param $a anyref) (result anyref)
    (if (result anyref) (call $is_int (local.get $a))
      (then (call $make_int (i64.sub (i64.const 0) (call $as_int (local.get $a)))))
      (else (call $make_float (f64.neg (call $as_float (local.get $a)))))))

  (func $lua_not (param $a anyref) (result anyref)
    (call $lua_bool_to_ref (i32.eqz (call $lua_truthy (local.get $a)))))

  (func $lua_len (param $a anyref) (result anyref)
    (if (result anyref) (ref.test (ref $LuaTable) (local.get $a))
      (then (call $make_int (i64.extend_i32_s
              (call $tab_len (ref.cast (ref $LuaTable) (local.get $a))))))
      (else (call $make_int (i64.extend_i32_u
        (array.len (struct.get $LuaString $bytes
          (ref.cast (ref $LuaString) (local.get $a)))))))))

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
  (func $lua_lt_raw (param $a anyref) (param $b anyref) (result i32)
    (if (i32.and
          (i32.or (call $is_int (local.get $a)) (call $is_float (local.get $a)))
          (i32.or (call $is_int (local.get $b)) (call $is_float (local.get $b))))
      (then (return (call $num_lt (local.get $a) (local.get $b)))))
    (if (i32.and (ref.test (ref $LuaString) (local.get $a))
                 (ref.test (ref $LuaString) (local.get $b)))
      (then (return (call $str_lt (local.get $a) (local.get $b)))))
    (throw $LuaError (ref.null any))
    (i32.const 0))

  (func $lua_le_raw (param $a anyref) (param $b anyref) (result i32)
    (if (i32.and
          (i32.or (call $is_int (local.get $a)) (call $is_float (local.get $a)))
          (i32.or (call $is_int (local.get $b)) (call $is_float (local.get $b))))
      (then (return (call $num_le (local.get $a) (local.get $b)))))
    (if (i32.and (ref.test (ref $LuaString) (local.get $a))
                 (ref.test (ref $LuaString) (local.get $b)))
      ;; a <= b iff not (b < a)
      (then (return (i32.eqz (call $str_lt (local.get $b) (local.get $a))))))
    (throw $LuaError (ref.null any))
    (i32.const 0))

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
      (then (throw $LuaError (ref.null any))))
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

  (global $g_mkey_index (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_add   (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_eq    (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_mkey_call  (mut (ref null $LuaString)) (ref.null $LuaString))
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
    ;; Single arg: pass the raw value through so the host's value formatter
    ;; can render floats etc. without going through wasm-side tostring (which
    ;; currently returns the "<float>" placeholder for floats).
    (if (i32.eq (local.get $n) (i32.const 1))
      (then
        (call $host_print (call $args_at (local.get $args) (i32.const 0)))
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
  (func $builtin_io_read (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32)
    (local.set $n (call $host_read))
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (array.new_fixed $ArgArr 1 (call $fmt_buf_to_str (local.get $n))))

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
    (local $t (ref $LuaTable)) (local $mt anyref)
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $mt (call $args_at (local.get $args) (i32.const 1)))
    (if (ref.is_null (local.get $mt))
      (then (struct.set $LuaTable $meta (local.get $t) (ref.null $LuaTable)))
      (else (struct.set $LuaTable $meta (local.get $t)
        (ref.cast (ref $LuaTable) (local.get $mt)))))
    (array.new_fixed $ArgArr 1 (local.get $t)))

  (func $builtin_getmetatable (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable))
    (local.set $t (ref.cast (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0))))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
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
  (func $builtin_string_format (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $fmt (ref $LuaArr))
    (local $n i32) (local $i i32) (local $j i32)
    (local $acc anyref) (local $b i32) (local $conv i32) (local $prec i32)
    (local $arg_idx i32) (local $piece (ref $LuaArr))
    (local $arg anyref) (local $written i32)
    (local.set $fmt (struct.get $LuaString $bytes
      (ref.cast (ref $LuaString) (call $args_at (local.get $args) (i32.const 0)))))
    (local.set $n (array.len (local.get $fmt)))
    (local.set $acc (ref.as_non_null (global.get $g_empty_str)))
    (local.set $arg_idx (i32.const 1))
    (block $done (loop $main
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $i)))
      (if (i32.ne (local.get $b) (i32.const 37))     ;; not '%' -> collect run
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
      ;; here $b == '%'
      (if (i32.ge_s (i32.add (local.get $i) (i32.const 1)) (local.get $n))
        (then (br $done)))
      ;; %% -> literal %
      (if (i32.eq (array.get_u $LuaArr (local.get $fmt) (i32.add (local.get $i) (i32.const 1)))
                  (i32.const 37))
        (then
          (local.set $piece (array.new $LuaArr (i32.const 37) (i32.const 1)))
          (local.set $acc (call $lua_concat (local.get $acc)
                            (struct.new $LuaString (local.get $piece))))
          (local.set $i (i32.add (local.get $i) (i32.const 2)))
          (br $main)))
      ;; parse optional .NNN precision after the %
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (local.set $prec (i32.const -1))
      (if (i32.eq (array.get_u $LuaArr (local.get $fmt) (local.get $i)) (i32.const 46))
        (then
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (local.set $prec (i32.const 0))
          (block $pdone (loop $ploop
            (br_if $pdone (i32.ge_s (local.get $i) (local.get $n)))
            (local.set $b (array.get_u $LuaArr (local.get $fmt) (local.get $i)))
            (br_if $pdone (i32.or (i32.lt_s (local.get $b) (i32.const 48))
                                   (i32.gt_s (local.get $b) (i32.const 57))))
            (local.set $prec
              (i32.add (i32.mul (local.get $prec) (i32.const 10))
                        (i32.sub (local.get $b) (i32.const 48))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $ploop)))))
      ;; conversion char
      (if (i32.ge_s (local.get $i) (local.get $n)) (then (br $done)))
      (local.set $conv (array.get_u $LuaArr (local.get $fmt) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (local.set $arg (call $args_at (local.get $args) (local.get $arg_idx)))
      (local.set $arg_idx (i32.add (local.get $arg_idx) (i32.const 1)))
      ;; dispatch
      (if (i32.eq (local.get $conv) (i32.const 115))   ;; 's'
        (then
          (local.set $acc (call $lua_concat (local.get $acc)
                            (call $lua_tostring (local.get $arg))))
          (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 100))   ;; 'd'
        (then
          (local.set $written (call $host_fmt (i32.const 0)
                                (call $as_int (local.get $arg)) (f64.const 0)
                                (local.get $prec)))
          (local.set $acc (call $lua_concat (local.get $acc)
                            (call $fmt_buf_to_str (local.get $written))))
          (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 120))   ;; 'x'
        (then
          (local.set $written (call $host_fmt (i32.const 5)
                                (call $as_int (local.get $arg)) (f64.const 0)
                                (local.get $prec)))
          (local.set $acc (call $lua_concat (local.get $acc)
                            (call $fmt_buf_to_str (local.get $written))))
          (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 103))   ;; 'g'
        (then
          (local.set $written (call $host_fmt (i32.const 2)
                                (i64.const 0) (call $as_float (local.get $arg))
                                (local.get $prec)))
          (local.set $acc (call $lua_concat (local.get $acc)
                            (call $fmt_buf_to_str (local.get $written))))
          (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 102))   ;; 'f'
        (then
          (local.set $written (call $host_fmt (i32.const 3)
                                (i64.const 0) (call $as_float (local.get $arg))
                                (local.get $prec)))
          (local.set $acc (call $lua_concat (local.get $acc)
                            (call $fmt_buf_to_str (local.get $written))))
          (br $main)))
      (if (i32.eq (local.get $conv) (i32.const 101))   ;; 'e'
        (then
          (local.set $written (call $host_fmt (i32.const 4)
                                (i64.const 0) (call $as_float (local.get $arg))
                                (local.get $prec)))
          (local.set $acc (call $lua_concat (local.get $acc)
                            (call $fmt_buf_to_str (local.get $written))))
          (br $main)))
      ;; unknown conversion — just skip
      (br $main)))
    (array.new_fixed $ArgArr 1 (call $lua_tostring (local.get $acc))))

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
