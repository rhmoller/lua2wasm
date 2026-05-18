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
  (type $TArr (array (mut anyref)))
  (rec
    (type $LuaTable (sub (struct
      (field $keys (mut (ref null $TArr)))
      (field $vals (mut (ref null $TArr)))
      (field $n    (mut i32))
      (field $cap  (mut i32))
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
  ;; host_read: read next line from stdin into $fmt_buf and return the
  ;; length; returns -1 on EOF.
  (import "host" "read" (func $host_read (result i32)))

  ;; --- singletons ---
  (global $g_true  (ref $LuaBool) (struct.new $LuaBool (i32.const 1)))
  (global $g_false (ref $LuaBool) (struct.new $LuaBool (i32.const 0)))
  (global $g_empty_upvals (ref $UpvalArr) (array.new_fixed $UpvalArr 0))
  (global $g_empty_args   (ref $ArgArr)   (array.new_fixed $ArgArr 0))
  ;; Scratch byte buffer that host_fmt writes into (set up by stdlib_init).
  (global $fmt_buf (mut (ref null $LuaArr)) (ref.null $LuaArr))
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

  (func $lua_fdiv (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (call $make_int (i64.div_s (call $as_int (local.get $a))
                                       (call $as_int (local.get $b)))))
      (else (call $make_float (f64.floor
              (f64.div (call $as_float (local.get $a))
                       (call $as_float (local.get $b))))))))

  (func $lua_mod (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (call $make_int (i64.rem_s (call $as_int (local.get $a))
                                       (call $as_int (local.get $b)))))
      (else (call $make_float (f64.const 0)))))   ;; v2 stub: float % returns 0

  (func $lua_pow (param $a anyref) (param $b anyref) (result anyref)
    (local $base f64) (local $exp f64) (local $r f64) (local $i i32)
    (local.set $base (call $as_float (local.get $a)))
    (local.set $exp  (call $as_float (local.get $b)))
    (local.set $r (f64.const 1))
    (local.set $i (i32.trunc_f64_s (local.get $exp)))
    (block $done (loop $lp
      (br_if $done (i32.le_s (local.get $i) (i32.const 0)))
      (local.set $r (f64.mul (local.get $r) (local.get $base)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $make_float (local.get $r)))

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

  (func $lua_lt (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $num_lt (local.get $a) (local.get $b))))
  (func $lua_le (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $num_le (local.get $a) (local.get $b))))
  (func $lua_gt (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $num_lt (local.get $b) (local.get $a))))
  (func $lua_ge (param $a anyref) (param $b anyref) (result anyref)
    (call $lua_bool_to_ref (call $num_le (local.get $b) (local.get $a))))

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
    (if (result (ref $LuaString)) (ref.is_null (local.get $v))
      (then (struct.new $LuaString (array.new_data $LuaArr $str_data
               (i32.const 0) (i32.const 3))))
      (else (if (result (ref $LuaString)) (ref.test (ref $LuaBool) (local.get $v))
        (then (if (result (ref $LuaString))
                  (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v)))
          (then (struct.new $LuaString (array.new_data $LuaArr $str_data
                  (i32.const 3) (i32.const 4))))
          (else (struct.new $LuaString (array.new_data $LuaArr $str_data
                  (i32.const 7) (i32.const 5))))))
        (else (if (result (ref $LuaString)) (ref.test (ref $LuaString) (local.get $v))
          (then (ref.cast (ref $LuaString) (local.get $v)))
          (else (if (result (ref $LuaString)) (call $is_int (local.get $v))
            (then (struct.new $LuaString (call $int_to_bytes (call $as_int (local.get $v)))))
            (else (struct.new $LuaString (call $float_to_bytes (call $as_float (local.get $v)))))))))))))

  (func $lua_concat (param $a anyref) (param $b anyref) (result anyref)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr)) (local $out (ref $LuaArr))
    (local $na i32) (local $nb i32)
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

  ;; --- tables (linear-search hash; perf is a phase-7 concern) ---
  (func $tab_new (result (ref $LuaTable))
    (struct.new $LuaTable (ref.null $TArr) (ref.null $TArr) (i32.const 0) (i32.const 0) (ref.null $LuaTable)))

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

  ;; Linear scan; returns index in 0..n-1 or -1 if not present.
  (func $tab_find (param $t (ref $LuaTable)) (param $k anyref) (result i32)
    (local $keys (ref null $TArr)) (local $n i32) (local $i i32)
    (local.set $keys (struct.get $LuaTable $keys (local.get $t)))
    (local.set $n (struct.get $LuaTable $n (local.get $t)))
    (if (ref.is_null (local.get $keys)) (then (return (i32.const -1))))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (if (call $lua_eq_raw
            (array.get $TArr (ref.as_non_null (local.get $keys)) (local.get $i))
            (local.get $k))
        (then (return (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.const -1))

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
  (global $g_tab_str    (mut (ref null $LuaString)) (ref.null $LuaString))
  (global $g_empty_str  (mut (ref null $LuaString)) (ref.null $LuaString))

  (func $tab_set (param $t (ref $LuaTable)) (param $k anyref) (param $v anyref)
    (local $i i32) (local $n i32) (local $cap i32)
    (local $keys (ref null $TArr)) (local $vals (ref null $TArr))
    (local.set $i (call $tab_find (local.get $t) (local.get $k)))
    (if (i32.ge_s (local.get $i) (i32.const 0))
      (then
        ;; existing key: update or delete
        (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
        (if (ref.is_null (local.get $v))
          (then
            ;; delete: swap with last and shrink
            (local.set $n (i32.sub (struct.get $LuaTable $n (local.get $t)) (i32.const 1)))
            (local.set $keys (struct.get $LuaTable $keys (local.get $t)))
            (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $i)
              (array.get $TArr (ref.as_non_null (local.get $keys)) (local.get $n)))
            (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $i)
              (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $n)))
            (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $n) (ref.null any))
            (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $n) (ref.null any))
            (struct.set $LuaTable $n (local.get $t) (local.get $n)))
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
    (local.set $keys (struct.get $LuaTable $keys (local.get $t)))
    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
    (array.set $TArr (ref.as_non_null (local.get $keys)) (local.get $n) (local.get $k))
    (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $n) (local.get $v))
    (struct.set $LuaTable $n (local.get $t) (i32.add (local.get $n) (i32.const 1))))

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
    ;; Multi-arg: stringify and join with TAB on the wasm side, then print.
    (local.set $acc (call $args_at (local.get $args) (i32.const 0)))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $acc
        (call $lua_concat
          (call $lua_concat (local.get $acc)
                            (ref.as_non_null (global.get $g_tab_str)))
          (call $args_at (local.get $args) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $host_print (call $lua_tostring (local.get $acc)))
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
    (local.set $acc (call $args_at (local.get $args) (i32.const 0)))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $acc (call $lua_concat (local.get $acc)
                       (call $args_at (local.get $args) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $host_write_raw (call $lua_tostring (local.get $acc)))
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

  ;; tonumber: numbers passthrough, strings parsed as ints (simple form),
  ;; everything else returns nil. (Phase-7 limitation.)
  (func $builtin_tonumber (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref) (local $bytes (ref $LuaArr))
    (local $n i32) (local $i i32) (local $acc i64) (local $neg i32) (local $b i32)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
      (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $v)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $bytes (struct.get $LuaString $bytes
                        (ref.cast (ref $LuaString) (local.get $v))))
    (local.set $n (array.len (local.get $bytes)))
    (if (i32.eqz (local.get $n))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (if (i32.eq (array.get_u $LuaArr (local.get $bytes) (i32.const 0)) (i32.const 45))
      (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1))))
    (if (i32.ge_s (local.get $i) (local.get $n))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $b (array.get_u $LuaArr (local.get $bytes) (local.get $i)))
      (if (i32.or (i32.lt_s (local.get $b) (i32.const 48))
                  (i32.gt_s (local.get $b) (i32.const 57)))
        (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
      (local.set $acc (i64.add (i64.mul (local.get $acc) (i64.const 10))
                                (i64.extend_i32_u
                                  (i32.sub (local.get $b) (i32.const 48)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (if (local.get $neg)
      (then (local.set $acc (i64.sub (i64.const 0) (local.get $acc)))))
    (array.new_fixed $ArgArr 1 (call $make_int (local.get $acc))))

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
      (global.get $g_builtin__ipairs_iter)
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
  (func $builtin_math_atan (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 5) (local.get $args)))
  (func $builtin_math_exp  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 6) (local.get $args)))
  (func $builtin_math_log  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 7) (local.get $args)))

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
  ;; JS-side writer for the format scratch buffer.
  (func (export "fmt_buf_set") (param $i i32) (param $b i32)
    (array.set $LuaArr (ref.as_non_null (global.get $fmt_buf))
      (local.get $i) (local.get $b)))
