;; The operators: arithmetic, bitwise and comparison, each with its
;; metamethod fallback, and the integer floor division/modulo codegen calls.

  ;; --- arithmetic: int+int -> int; else promote to float ---
  (func $is_numlike (param $v anyref) (result i32)
    (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v))))

  ;; Coerce a value to its numeric form for an arithmetic operation:
  ;; numbers pass through, strings are parsed per Lua's tonumber rules,
  ;; everything else yields nil. Callers fall back to the metamethod
  ;; path when this returns nil for either operand. The original (un-
  ;; coerced) value must still be passed to arith_mm so the metamethod
  ;; sees what the user actually wrote.
  (func $coerce_num (param $v anyref) (result anyref)
    (if (result anyref) (call $is_numlike (local.get $v))
      (then (local.get $v))
      (else
        (if (result anyref) (ref.test (ref $LuaString) (local.get $v))
          (then (call $host_parse_num (local.get $v) (i32.const 0)))
          (else (ref.null any))))))

  ;; Try a binary arithmetic metamethod: lookup $key on a, then b.
  ;; Returns the metamethod's first result if found; throws otherwise.
  (func $arith_mm (param $a anyref) (param $b anyref)
                  (param $key (ref $LuaString)) (result anyref)
    (local $mm anyref)
    (local.set $mm (call $get_metamethod (local.get $a) (local.get $key)))
    (if (ref.is_null (local.get $mm))
      (then (local.set $mm (call $get_metamethod (local.get $b) (local.get $key)))))
    (if (ref.is_null (local.get $mm))
      (then (call $throw_lit (i32.const 208) (i32.const 29))))   ;; "attempt to perform arithmetic"
    (call $call_mm1 (local.get $mm) (local.get $a) (local.get $b) (ref.null any) (i32.const 2)))

  (func $lua_add (param $a anyref) (param $b anyref) (result anyref)
    (local $ca anyref) (local $cb anyref)
    ;; Fast path: small-int + small-int (both i31). i31.get_s sign-extends the
    ;; 31-bit payload; the i64 sum is exact and $make_int re-boxes (i31 or
    ;; $LuaInt) identically to the general path below.
    (if (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (return (call $make_int (i64.add
        (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $a))))
        (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $b)))))))))
    ;; Fast path: float + float.
    (if (i32.and (ref.test (ref $LuaFloat) (local.get $a)) (ref.test (ref $LuaFloat) (local.get $b)))
      (then (return (call $make_float (f64.add
        (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $a)))
        (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $b))))))))
    (local.set $ca (call $coerce_num (local.get $a)))
    (local.set $cb (call $coerce_num (local.get $b)))
    (if (i32.and (call $is_numlike (local.get $ca)) (call $is_numlike (local.get $cb)))
      (then
        (if (i32.and (call $is_int (local.get $ca)) (call $is_int (local.get $cb)))
          (then (return (call $make_int (i64.add (call $as_int (local.get $ca))
                                                  (call $as_int (local.get $cb)))))))
        (return (call $make_float (f64.add (call $as_float (local.get $ca))
                                            (call $as_float (local.get $cb)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_add))))

  (func $lua_sub (param $a anyref) (param $b anyref) (result anyref)
    (local $ca anyref) (local $cb anyref)
    (if (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (return (call $make_int (i64.sub
        (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $a))))
        (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $b)))))))))
    (if (i32.and (ref.test (ref $LuaFloat) (local.get $a)) (ref.test (ref $LuaFloat) (local.get $b)))
      (then (return (call $make_float (f64.sub
        (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $a)))
        (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $b))))))))
    (local.set $ca (call $coerce_num (local.get $a)))
    (local.set $cb (call $coerce_num (local.get $b)))
    (if (i32.and (call $is_numlike (local.get $ca)) (call $is_numlike (local.get $cb)))
      (then
        (if (i32.and (call $is_int (local.get $ca)) (call $is_int (local.get $cb)))
          (then (return (call $make_int (i64.sub (call $as_int (local.get $ca))
                                                  (call $as_int (local.get $cb)))))))
        (return (call $make_float (f64.sub (call $as_float (local.get $ca))
                                            (call $as_float (local.get $cb)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_sub))))

  (func $lua_mul (param $a anyref) (param $b anyref) (result anyref)
    (local $ca anyref) (local $cb anyref)
    ;; Two sign-extended 31-bit values multiply within i64 range (≈60 bits), so
    ;; the product is exact; $make_int re-boxes as the general path would.
    (if (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (return (call $make_int (i64.mul
        (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $a))))
        (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $b)))))))))
    (if (i32.and (ref.test (ref $LuaFloat) (local.get $a)) (ref.test (ref $LuaFloat) (local.get $b)))
      (then (return (call $make_float (f64.mul
        (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $a)))
        (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $b))))))))
    (local.set $ca (call $coerce_num (local.get $a)))
    (local.set $cb (call $coerce_num (local.get $b)))
    (if (i32.and (call $is_numlike (local.get $ca)) (call $is_numlike (local.get $cb)))
      (then
        (if (i32.and (call $is_int (local.get $ca)) (call $is_int (local.get $cb)))
          (then (return (call $make_int (i64.mul (call $as_int (local.get $ca))
                                                  (call $as_int (local.get $cb)))))))
        (return (call $make_float (f64.mul (call $as_float (local.get $ca))
                                            (call $as_float (local.get $cb)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_mul))))

  ;; / always yields float (Lua 5.4/5.5)
  (func $lua_div (param $a anyref) (param $b anyref) (result anyref)
    (local $ca anyref) (local $cb anyref)
    ;; Fast path: float / float (/ always yields float, so no int special-case).
    (if (i32.and (ref.test (ref $LuaFloat) (local.get $a)) (ref.test (ref $LuaFloat) (local.get $b)))
      (then (return (call $make_float (f64.div
        (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $a)))
        (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $b))))))))
    (local.set $ca (call $coerce_num (local.get $a)))
    (local.set $cb (call $coerce_num (local.get $b)))
    (if (i32.and (call $is_numlike (local.get $ca)) (call $is_numlike (local.get $cb)))
      (then (return (call $make_float (f64.div (call $as_float (local.get $ca))
                                                (call $as_float (local.get $cb)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_div))))

  ;; Floor division: q = floor(a/b). For ints, i64.div_s truncates toward
  ;; zero, which differs from floor when signs disagree and there's a
  ;; non-zero remainder. Same correction pattern as $lua_mod: subtract 1
  ;; iff there's a remainder AND the operand signs disagree.
  (func $lua_fdiv (param $a anyref) (param $b anyref) (result anyref)
    (local $ai i64) (local $bi i64) (local $q i64) (local $r i64)
    (local $ca anyref) (local $cb anyref)
    (local.set $ca (call $coerce_num (local.get $a)))
    (local.set $cb (call $coerce_num (local.get $b)))
    (if (i32.and (call $is_int (local.get $ca)) (call $is_int (local.get $cb)))
      (then
        (local.set $ai (call $as_int (local.get $ca)))
        (local.set $bi (call $as_int (local.get $cb)))
        ;; Match reference Lua: divisor 0 is an error; divisor -1 returns
        ;; (0 - ai) so the wasm trap on INT64_MIN/-1 ("divide result
        ;; unrepresentable") never fires. Subtraction in wasm wraps, so
        ;; INT64_MIN // -1 → INT64_MIN, exactly like real-Lua's overflow.
        (if (i64.eqz (local.get $bi))
          (then (call $throw_lit (i32.const 430) (i32.const 25))))   ;; "attempt to divide by zero"
        (if (i64.eq (local.get $bi) (i64.const -1))
          (then (return (call $make_int
            (i64.sub (i64.const 0) (local.get $ai))))))
        (local.set $q (i64.div_s (local.get $ai) (local.get $bi)))
        (local.set $r (i64.rem_s (local.get $ai) (local.get $bi)))
        (if (i32.and
              (i64.ne (local.get $r) (i64.const 0))
              (i64.lt_s (i64.xor (local.get $ai) (local.get $bi)) (i64.const 0)))
          (then (local.set $q (i64.sub (local.get $q) (i64.const 1)))))
        (return (call $make_int (local.get $q)))))
    (if (i32.and (call $is_numlike (local.get $ca)) (call $is_numlike (local.get $cb)))
      (then (return (call $make_float (f64.floor
        (f64.div (call $as_float (local.get $ca))
                 (call $as_float (local.get $cb))))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_idiv))))

  ;; Floor modulo: a - floor(a/b)*b. Differs from truncating remainder
  ;; (i64.rem_s, C's `%`) when the operands have different signs.
  ;; Integer case: start with rem_s and adjust by +b when the remainder
  ;; is non-zero and the operand signs disagree.
  ;; Float case: a - floor(a/b)*b directly.
  (func $lua_mod (param $a anyref) (param $b anyref) (result anyref)
    (local $ai i64) (local $bi i64) (local $r i64)
    (local $af f64) (local $bf f64) (local $mf f64)
    (local $ca anyref) (local $cb anyref)
    (local.set $ca (call $coerce_num (local.get $a)))
    (local.set $cb (call $coerce_num (local.get $b)))
    (if (i32.and (call $is_int (local.get $ca)) (call $is_int (local.get $cb)))
      (then
        (local.set $ai (call $as_int (local.get $ca)))
        (local.set $bi (call $as_int (local.get $cb)))
        ;; Divisor 0 → spec error; divisor -1 short-circuits to 0 (i64.rem_s
        ;; on INT64_MIN/-1 doesn't trap on every engine but is implementation-
        ;; defined; explicit short-circuit is portable).
        (if (i64.eqz (local.get $bi))
          (then (call $throw_lit (i32.const 455) (i32.const 24))))   ;; "attempt to perform 'n%0'"
        (if (i64.eq (local.get $bi) (i64.const -1))
          (then (return (call $make_int (i64.const 0)))))
        (local.set $r  (i64.rem_s (local.get $ai) (local.get $bi)))
        (if (i32.and
              (i64.ne (local.get $r) (i64.const 0))
              (i64.lt_s (i64.xor (local.get $ai) (local.get $bi)) (i64.const 0)))
          (then (local.set $r (i64.add (local.get $r) (local.get $bi)))))
        (return (call $make_int (local.get $r)))))
    (if (i32.and (call $is_numlike (local.get $ca)) (call $is_numlike (local.get $cb)))
      (then
        (local.set $af (call $as_float (local.get $ca)))
        (local.set $bf (call $as_float (local.get $cb)))
        ;; Floor-mod via fmod, like Lua's luai_nummod: m = fmod(a,b) keeps the
        ;; dividend's sign (incl. ±0); add b once when m is nonzero and its sign
        ;; differs from b's, to bring it into the divisor's half-open range. A
        ;; plain a-floor(a/b)*b instead yields +0 for every exact division.
        (local.set $mf (call $host_math2 (i32.const 2) (local.get $af) (local.get $bf)))
        (if (i32.and (f64.ne (local.get $mf) (f64.const 0))
                     (i32.ne (f64.lt (local.get $mf) (f64.const 0))
                             (f64.lt (local.get $bf) (f64.const 0))))
          (then (local.set $mf (f64.add (local.get $mf) (local.get $bf)))))
        (return (call $make_float (local.get $mf)))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_mod))))

  ;; `^` is always-float per Lua spec. Routes to host pow so that
  ;; non-integer exponents (2^0.5), negative exponents (2^-1), and
  ;; mixed-sign edge cases (NaN, inf, 0^0) all match IEEE-754 pow.
  (func $lua_pow (param $a anyref) (param $b anyref) (result anyref)
    (local $ca anyref) (local $cb anyref)
    (local.set $ca (call $coerce_num (local.get $a)))
    (local.set $cb (call $coerce_num (local.get $b)))
    (if (i32.and (call $is_numlike (local.get $ca)) (call $is_numlike (local.get $cb)))
      (then (return (call $make_float
        (call $host_math2 (i32.const 1)
          (call $as_float (local.get $ca))
          (call $as_float (local.get $cb)))))))
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
  ;; Each binary bitop: try both operands as integers; if both convert, run the
  ;; op, else dispatch through the metamethod $key. Codegen calls these directly
  ;; (BIN_BAND -> $lua_band, …), so there is no separate wrapper layer.
  (func $lua_band (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (i64.and (call $as_int_unchecked (local.get $a))
                 (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_band))))

  (func $lua_bor (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (i64.or  (call $as_int_unchecked (local.get $a))
                 (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_bor))))

  (func $lua_bxor (param $a anyref) (param $b anyref) (result anyref)
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

  (func $lua_shl (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (call $do_shl (call $as_int_unchecked (local.get $a))
                       (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_shl))))

  (func $lua_shr (param $a anyref) (param $b anyref) (result anyref)
    (if (i32.and (call $try_to_int (local.get $a))
                 (call $try_to_int (local.get $b)))
      (then (return (call $make_int
        (call $do_shr (call $as_int_unchecked (local.get $a))
                       (call $as_int_unchecked (local.get $b)))))))
    (call $arith_mm (local.get $a) (local.get $b)
      (ref.as_non_null (global.get $g_mkey_shr))))

  ;; Unary bitwise NOT: ~v.
  (func $lua_bnot (param $a anyref) (result anyref)
    (local $mm anyref)
    (if (call $try_to_int (local.get $a))
      (then (return (call $make_int
        (i64.xor (call $as_int_unchecked (local.get $a)) (i64.const -1))))))
    (local.set $mm (call $get_metamethod (local.get $a)
      (ref.as_non_null (global.get $g_mkey_bnot))))
    (if (ref.is_null (local.get $mm))
      (then (call $throw_lit (i32.const 208) (i32.const 29))))   ;; "attempt to perform arithmetic"
    (call $call_mm1 (local.get $mm) (local.get $a) (local.get $a) (ref.null any) (i32.const 2)))

  (func $lua_neg (param $a anyref) (result anyref)
    (local $mm anyref) (local $ca anyref)
    (local.set $ca (call $coerce_num (local.get $a)))
    (if (call $is_numlike (local.get $ca))
      (then
        (if (call $is_int (local.get $ca))
          (then (return (call $make_int (i64.sub (i64.const 0) (call $as_int (local.get $ca)))))))
        (return (call $make_float (f64.neg (call $as_float (local.get $ca)))))))
    (local.set $mm (call $get_metamethod (local.get $a)
      (ref.as_non_null (global.get $g_mkey_unm))))
    (if (ref.is_null (local.get $mm))
      (then (call $throw_lit (i32.const 208) (i32.const 29))))   ;; "attempt to perform arithmetic"
    ;; Per spec the metamethod is called with (a, a) for backward-compat.
    (call $call_mm1 (local.get $mm) (local.get $a) (local.get $a) (ref.null any) (i32.const 2)))


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
        (call $str_length (ref.cast (ref $LuaString) (local.get $a))))))))
    (if (ref.test (ref $LuaTable) (local.get $a))
      (then
        (local.set $mm (call $get_metamethod (local.get $a)
          (ref.as_non_null (global.get $g_mkey_len))))
        (if (ref.is_null (local.get $mm))
          (then (return (call $make_int (i64.extend_i32_s
            (call $tab_len (ref.cast (ref $LuaTable) (local.get $a))))))))
        (return (call $call_mm1 (local.get $mm) (local.get $a) (ref.null any) (ref.null any) (i32.const 1)))))
    (local.set $mm (call $get_metamethod (local.get $a)
      (ref.as_non_null (global.get $g_mkey_len))))
    (if (ref.is_null (local.get $mm))
      (then (call $throw_lit (i32.const 237) (i32.const 24))))   ;; "attempt to index a value" (closest available)
    (call $call_mm1 (local.get $mm) (local.get $a) (ref.null any) (ref.null any) (i32.const 1)))

  ;; --- comparison ---
  ;; Equality on the numeric type pair. The mixed int-vs-float case can't
  ;; just promote both to f64 and use f64.eq: an i64 outside ±2^53 loses
  ;; precision in the conversion, so e.g. 9007199254740993 (int) would
  ;; compare equal to 2.0^53 (float). Convert the float to int if and only
  ;; if it has no fractional part AND fits in signed i64; otherwise the
  ;; values are unequal by construction.
  (func $num_eq (param $a anyref) (param $b anyref) (result i32)
    (local $fa f64) (local $ia i64)
    (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (return (i64.eq (call $as_int (local.get $a))
                            (call $as_int (local.get $b))))))
    (if (i32.and (call $is_float (local.get $a)) (call $is_float (local.get $b)))
      (then (return (f64.eq (call $as_float (local.get $a))
                            (call $as_float (local.get $b))))))
    ;; Mixed: arrange (int, float) into ($ia, $fa) regardless of order.
    (if (call $is_int (local.get $a))
      (then (local.set $ia (call $as_int (local.get $a)))
            (local.set $fa (call $as_float (local.get $b))))
      (else (local.set $ia (call $as_int (local.get $b)))
            (local.set $fa (call $as_float (local.get $a)))))
    (call $int_eq_float (local.get $ia) (local.get $fa)))

  (func $str_eq (param $a anyref) (param $b anyref) (result i32)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr))
    (local $ra (ref null $LuaArr)) (local $rb (ref null $LuaArr))
    (local $i i32) (local $n i32) (local $ha i32) (local $hb i32)
    ;; Same object (hoisted constants, keys read back out of a table): equal.
    (if (ref.eq (ref.cast (ref eq) (local.get $a)) (ref.cast (ref eq) (local.get $b)))
      (then (return (i32.const 1))))
    ;; Two computed hashes that differ settle it without touching the bytes.
    (local.set $ha (struct.get $LuaString $hash (ref.cast (ref $LuaString) (local.get $a))))
    (local.set $hb (struct.get $LuaString $hash (ref.cast (ref $LuaString) (local.get $b))))
    (if (i32.and (i32.and (local.get $ha) (local.get $hb)) (i32.ne (local.get $ha) (local.get $hb)))
      (then (return (i32.const 0))))
    ;; So do two lengths, before a lazy string is flattened for its bytes.
    (local.set $ra (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $a))))
    (local.set $rb (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $b))))
    (if (i32.or (ref.is_null (local.get $ra)) (ref.is_null (local.get $rb)))
      (then
        (if (i32.ne (call $str_length (ref.cast (ref $LuaString) (local.get $a)))
                    (call $str_length (ref.cast (ref $LuaString) (local.get $b))))
          (then (return (i32.const 0))))
        (local.set $ra (call $str_bytes (ref.cast (ref $LuaString) (local.get $a))))
        (local.set $rb (call $str_bytes (ref.cast (ref $LuaString) (local.get $b))))))
    (local.set $sa (ref.as_non_null (local.get $ra)))
    (local.set $sb (ref.as_non_null (local.get $rb)))
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
    ;; Fast path for the dominant case (small-int keys / comparisons): two i31
    ;; refs are equal iff their sign-extended payloads match. An i31 holds only
    ;; a small integer here (never NaN, never bool/nil), so a direct value
    ;; compare is exact -- identical to the $num_eq result below -- and it skips
    ;; the null/bool/numlike cascade plus the $num_eq dispatch.
    (if (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (return (i32.eq (i31.get_s (ref.cast (ref i31) (local.get $a)))
                            (i31.get_s (ref.cast (ref i31) (local.get $b)))))))
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
        (return (call $lua_truthy
          (call $call_mm1 (local.get $mm) (local.get $a) (local.get $b) (ref.null any) (i32.const 2))))))
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

  ;; Mixed int-vs-float ordering: a naive f64.lt((f64)i, f) loses precision
  ;; when i exceeds ±2^53 (e.g. maxint=2^63-1 rounds up to 2^63 and would
  ;; compare equal to 2.0^63). For correctness we split into cases by the
  ;; float's relationship to the i64 range and the integral part of f.
  (func $int_lt_float (param $i i64) (param $f f64) (result i32)
    (if (f64.ne (local.get $f) (local.get $f)) (then (return (i32.const 0))))   ;; NaN
    (if (f64.ge (local.get $f) (f64.const  9223372036854775808.0))
      (then (return (i32.const 1))))   ;; any i64 < 2^63 ≤ f
    (if (f64.lt (local.get $f) (f64.const -9223372036854775808.0))
      (then (return (i32.const 0))))   ;; any i64 ≥ -2^63 > f impossible
    ;; f is in [-2^63, 2^63). If f has no fractional part, compare as ints.
    ;; Otherwise i < f iff i ≤ floor(f).
    (if (f64.eq (local.get $f) (f64.floor (local.get $f)))
      (then (return (i64.lt_s (local.get $i) (i64.trunc_f64_s (local.get $f))))))
    (i64.le_s (local.get $i) (i64.trunc_f64_s (f64.floor (local.get $f)))))

  (func $float_lt_int (param $f f64) (param $i i64) (result i32)
    (if (f64.ne (local.get $f) (local.get $f)) (then (return (i32.const 0))))
    (if (f64.lt (local.get $f) (f64.const -9223372036854775808.0))
      (then (return (i32.const 1))))   ;; f < -2^63 ≤ i
    (if (f64.ge (local.get $f) (f64.const  9223372036854775808.0))
      (then (return (i32.const 0))))   ;; f ≥ 2^63 > i impossible
    ;; f has no fractional part → compare as ints. Else f < i iff ceil(f) ≤ i.
    (if (f64.eq (local.get $f) (f64.floor (local.get $f)))
      (then (return (i64.lt_s (i64.trunc_f64_s (local.get $f)) (local.get $i)))))
    (i64.le_s (i64.trunc_f64_s (f64.ceil (local.get $f))) (local.get $i)))

  (func $int_le_float (param $i i64) (param $f f64) (result i32)
    (if (f64.ne (local.get $f) (local.get $f)) (then (return (i32.const 0))))
    (if (f64.ge (local.get $f) (f64.const  9223372036854775808.0))
      (then (return (i32.const 1))))
    (if (f64.lt (local.get $f) (f64.const -9223372036854775808.0))
      (then (return (i32.const 0))))
    ;; i ≤ f iff i ≤ floor(f) (works regardless of f having a fractional part).
    (i64.le_s (local.get $i) (i64.trunc_f64_s (f64.floor (local.get $f)))))

  (func $float_le_int (param $f f64) (param $i i64) (result i32)
    (if (f64.ne (local.get $f) (local.get $f)) (then (return (i32.const 0))))
    (if (f64.lt (local.get $f) (f64.const -9223372036854775808.0))
      (then (return (i32.const 1))))
    (if (f64.ge (local.get $f) (f64.const  9223372036854775808.0))
      (then (return (i32.const 0))))
    ;; f ≤ i iff ceil(f) ≤ i.
    (i64.le_s (i64.trunc_f64_s (f64.ceil (local.get $f))) (local.get $i)))

  ;; Exact i == f: f must be integral and inside the i64 range (NaN fails the
  ;; integral test, ±inf the range test).
  (func $int_eq_float (param $i i64) (param $f f64) (result i32)
    (if (f64.ne (local.get $f) (f64.floor (local.get $f))) (then (return (i32.const 0))))
    (if (i32.or (f64.lt (local.get $f) (f64.const -9223372036854775808.0))
                (f64.ge (local.get $f) (f64.const  9223372036854775808.0)))
      (then (return (i32.const 0))))
    (i64.eq (local.get $i) (i64.trunc_f64_s (local.get $f))))

  ;; Operand-order counterparts of the above, so specialized comparisons pass
  ;; their operands in source order whichever side is the integer.
  (func $int_gt_float (param $i i64) (param $f f64) (result i32)
    (call $float_lt_int (local.get $f) (local.get $i)))
  (func $int_ge_float (param $i i64) (param $f f64) (result i32)
    (call $float_le_int (local.get $f) (local.get $i)))
  (func $float_gt_int (param $f f64) (param $i i64) (result i32)
    (call $int_lt_float (local.get $i) (local.get $f)))
  (func $float_ge_int (param $f f64) (param $i i64) (result i32)
    (call $int_le_float (local.get $i) (local.get $f)))
  (func $float_eq_int (param $f f64) (param $i i64) (result i32)
    (call $int_eq_float (local.get $i) (local.get $f)))

  (func $num_lt (param $a anyref) (param $b anyref) (result i32)
    (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (return (i64.lt_s (call $as_int (local.get $a))
                              (call $as_int (local.get $b))))))
    (if (i32.and (call $is_float (local.get $a)) (call $is_float (local.get $b)))
      (then (return (f64.lt (call $as_float (local.get $a))
                            (call $as_float (local.get $b))))))
    (if (call $is_int (local.get $a))
      (then (return (call $int_lt_float
        (call $as_int (local.get $a)) (call $as_float (local.get $b))))))
    (call $float_lt_int (call $as_float (local.get $a)) (call $as_int (local.get $b))))

  (func $num_le (param $a anyref) (param $b anyref) (result i32)
    (if (i32.and (call $is_int (local.get $a)) (call $is_int (local.get $b)))
      (then (return (i64.le_s (call $as_int (local.get $a))
                              (call $as_int (local.get $b))))))
    (if (i32.and (call $is_float (local.get $a)) (call $is_float (local.get $b)))
      (then (return (f64.le (call $as_float (local.get $a))
                            (call $as_float (local.get $b))))))
    (if (call $is_int (local.get $a))
      (then (return (call $int_le_float
        (call $as_int (local.get $a)) (call $as_float (local.get $b))))))
    (call $float_le_int (call $as_float (local.get $a)) (call $as_int (local.get $b))))

  ;; Byte-wise lexicographic compare of two LuaStrings. Returns 1 if
  ;; a < b, 0 otherwise (strictly less, not <=).
  (func $str_lt (param $a anyref) (param $b anyref) (result i32)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr))
    (local $na i32) (local $nb i32) (local $i i32) (local $min i32)
    (local $ba i32) (local $bb i32)
    (local.set $sa (call $str_bytes (ref.cast (ref $LuaString) (local.get $a))))
    (local.set $sb (call $str_bytes (ref.cast (ref $LuaString) (local.get $b))))
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
  ;; Anything else (incl. mixed types) -> __lt / __le metamethod, else
  ;; Lua error. Tries the left operand's metamethod first, then the
  ;; right; the truthiness of the first result is the answer.
  (func $compare_mm (param $a anyref) (param $b anyref)
                    (param $key (ref $LuaString)) (result i32)
    (local $mm anyref)
    (local.set $mm (call $get_metamethod (local.get $a) (local.get $key)))
    (if (ref.is_null (local.get $mm))
      (then (local.set $mm (call $get_metamethod (local.get $b) (local.get $key)))))
    (if (ref.is_null (local.get $mm))
      (then (call $throw_compare_error (local.get $a) (local.get $b)) (unreachable)))
    (call $lua_truthy
      (call $call_mm1 (local.get $mm) (local.get $a) (local.get $b) (ref.null any) (i32.const 2))))

  ;; Reference luaG_ordererror: "attempt to compare two <T> values" when both
  ;; operands share a type name, else "attempt to compare <T1> with <T2>".
  ;; Type names honour __name (via $objtypename). The file:line prefix is added
  ;; by $throw_at_top. Carved from the "attempt to compare two values" literal
  ;; (offset 479): "attempt to compare " (19), "attempt to compare two " (23),
  ;; " values" (7 from offset 501); " with " is built inline.
  (func $throw_compare_error (param $a anyref) (param $b anyref)
    (local $ta (ref $LuaArr)) (local $tb (ref $LuaArr))
    (local.set $ta (call $objtypename (local.get $a)))
    (local.set $tb (call $objtypename (local.get $b)))
    (if (call $str_eq (struct.new $LuaString (local.get $ta) (i32.const 0))
                      (struct.new $LuaString (local.get $tb) (i32.const 0)))
      (then (call $throw_at_top (ref.cast (ref $LuaString) (call $lua_concat
        (call $lua_concat
          (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 479) (i32.const 23)) (i32.const 0))
          (struct.new $LuaString (local.get $ta) (i32.const 0)))
        (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 501) (i32.const 7)) (i32.const 0)))))))
    (call $throw_at_top (ref.cast (ref $LuaString) (call $lua_concat
      (call $lua_concat
        (call $lua_concat
          (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 479) (i32.const 19)) (i32.const 0))
          (struct.new $LuaString (local.get $ta) (i32.const 0)))
        (struct.new $LuaString (array.new_fixed $LuaArr 6
          (i32.const 32) (i32.const 119) (i32.const 105) (i32.const 116) (i32.const 104) (i32.const 32)) (i32.const 0)))  ;; " with "
      (struct.new $LuaString (local.get $tb) (i32.const 0))))))

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

  ;; i64 floor-division and floor-modulo for the integer-specialization path
  ;; (LUA2WASM_OPT_INT). Same semantics as $lua_fdiv/$lua_mod on two integers
  ;; — floor toward -inf, divide-by-zero raises the catchable Lua error — but
  ;; operating on raw i64 with no boxing. The b==-1 guards avoid the wasm
  ;; INT64_MIN/-1 overflow trap (Lua wraps: x//-1 == -x, x%-1 == 0).
  (func $idiv_floor (param $a i64) (param $b i64) (result i64)
    (local $q i64)
    (if (i64.eqz (local.get $b))
      (then (call $throw_lit (i32.const 430) (i32.const 25)) (unreachable)))  ;; divide by zero
    (if (i64.eq (local.get $b) (i64.const -1))
      (then (return (i64.sub (i64.const 0) (local.get $a)))))
    (local.set $q (i64.div_s (local.get $a) (local.get $b)))
    (if (i32.and
          (i64.ne (i64.rem_s (local.get $a) (local.get $b)) (i64.const 0))
          (i32.ne (i64.lt_s (local.get $a) (i64.const 0))
                  (i64.lt_s (local.get $b) (i64.const 0))))
      (then (local.set $q (i64.sub (local.get $q) (i64.const 1)))))
    (local.get $q))

  (func $imod_floor (param $a i64) (param $b i64) (result i64)
    (local $r i64)
    (if (i64.eqz (local.get $b))
      (then (call $throw_lit (i32.const 455) (i32.const 24)) (unreachable)))  ;; 'n%0'
    (if (i64.eq (local.get $b) (i64.const -1))
      (then (return (i64.const 0))))
    (local.set $r (i64.rem_s (local.get $a) (local.get $b)))
    (if (i32.and
          (i64.ne (local.get $r) (i64.const 0))
          (i32.ne (i64.lt_s (local.get $r) (i64.const 0))
                  (i64.lt_s (local.get $b) (i64.const 0))))
      (then (local.set $r (i64.add (local.get $r) (local.get $b)))))
    (local.get $r))
