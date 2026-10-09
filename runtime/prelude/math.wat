;; The math library, including its xoshiro256** generator.

  ;; xoshiro256** state. Initial seed is fixed; user can call
  ;; math.randomseed(x [, y]) to override. Non-zero by construction.
  (global $g_rng0 (mut i64) (i64.const 0x9E3779B97F4A7C15))
  (global $g_rng1 (mut i64) (i64.const 0xBF58476D1CE4E5B9))
  (global $g_rng2 (mut i64) (i64.const 0x94D049BB133111EB))
  (global $g_rng3 (mut i64) (i64.const 0xD1B54A32D192ED03))

  ;; Coerce a math-library argument to f64: numbers pass through, numeric
  ;; strings parse (per tonumber), anything else raises a catchable
  ;; "number expected, got <type>" with the file:line prefix — instead of an
  ;; uncatchable illegal-cast trap. (Arithmetic operators already coerce via
  ;; $coerce_num; this brings the math library in line.) The is_int dispatch
  ;; in floor/ceil/abs/fmod still tests the *original* arg, so a numeric
  ;; string yields a float result, matching reference's lua_isinteger check.
  (func $throw_number_expected (param $v anyref)
    (call $throw_at_top (ref.cast (ref $LuaString) (call $lua_concat
      (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 950) (i32.const 21)) (i32.const 0))
      (struct.new $LuaString (call $basic_type_bytes (local.get $v)) (i32.const 0))))))
  (func $as_float_co (param $v anyref) (result f64)
    (local $c anyref)
    (local.set $c (call $coerce_num (local.get $v)))
    (if (ref.is_null (local.get $c))
      (then (call $throw_number_expected (local.get $v)) (unreachable)))
    (call $as_float (local.get $c)))

  ;; Integer analog of $as_float_co: a number or numeric string denoting an
  ;; exact integer passes through; a fractional / out-of-range value raises a
  ;; catchable "number has no integer representation"; a non-number raises
  ;; "number expected, got <type>". A small integer is read here and
  ;; anything else left to $as_int_co_slow, so that V8, inlining this into a
  ;; hot caller (string.sub's and string.byte's positions), keeps the
  ;; coercions out of line and its inlining budget for the rest.
  (func $as_int_co (param $v anyref) (result i64)
    (if (ref.test (ref i31) (local.get $v))
      (then (return (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $v)))))))
    (return_call $as_int_co_slow (local.get $v)))
  (func $as_int_co_slow (param $v anyref) (result i64)
    (local $c anyref) (local $f f64)
    (local.set $c (call $coerce_num (local.get $v)))
    (if (ref.is_null (local.get $c))
      (then (call $throw_number_expected (local.get $v)) (unreachable)))
    (if (call $is_int (local.get $c))
      (then (return (call $as_int (local.get $c)))))
    (local.set $f (call $as_float (local.get $c)))
    (if (i32.eqz (i32.and
          (f64.eq (local.get $f) (f64.trunc (local.get $f)))
          (i32.and
            (f64.eq (local.get $f) (local.get $f))
            (i32.and
              (f64.ge (local.get $f) (f64.const -9223372036854775808.0))
              (f64.lt (local.get $f) (f64.const  9223372036854775808.0))))))
      (then (call $throw_lit (i32.const 985) (i32.const 36)) (unreachable)))   ;; "number has no integer representation"
    (i64.trunc_f64_s (local.get $f)))

  ;; Convert an already-floored/ceiled float to a Lua integer when it lands
  ;; in [-2^63, 2^63) (mirrors lua_numbertointeger); otherwise leave it a
  ;; float. The range test also covers ±inf and NaN (both fail it), so they
  ;; pass through as floats instead of trapping i64.trunc_f64_s — reference
  ;; Lua returns math.floor(1e30)==1e30, math.floor(math.huge)==inf, etc.
  (func $f64_to_int_result (param $f f64) (result anyref)
    (if (result anyref)
      (i32.and (f64.ge (local.get $f) (f64.const -9.2233720368547758e+18))
               (f64.lt (local.get $f) (f64.const  9.2233720368547758e+18)))
      (then (call $make_int (i64.trunc_f64_s (local.get $f))))
      (else (call $make_float (local.get $f)))))

  ;; One-argument math functions: a core on the value, the generic entry
  ;; and the fast entry ($LuaFn1, see string.wat) around it.
  (func $math_floor (param $v anyref) (result anyref)
    (if (call $is_int (local.get $v)) (then (return (local.get $v))))
    (call $f64_to_int_result (f64.floor (call $as_float_co (local.get $v)))))
  (func $builtin_math_floor (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $math_floor (call $args_at (local.get $args) (i32.const 0)))))
  (func $builtin_math_floor_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $math_floor (local.get $a0)))

  (func $math_abs (param $v anyref) (result anyref)
    (local $i i64)
    (if (call $is_int (local.get $v))
      (then
        (local.set $i (call $as_int (local.get $v)))
        (if (i64.lt_s (local.get $i) (i64.const 0))
          (then (local.set $i (i64.sub (i64.const 0) (local.get $i)))))
        (return (call $make_int (local.get $i)))))
    (call $make_float (f64.abs (call $as_float_co (local.get $v)))))
  (func $builtin_math_abs (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $math_abs (call $args_at (local.get $args) (i32.const 0)))))
  (func $builtin_math_abs_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $math_abs (local.get $a0)))

  (func $builtin_math_sqrt (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $make_float (f64.sqrt (call $as_float_co
        (call $args_at (local.get $args) (i32.const 0)))))))
  (func $builtin_math_sqrt_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $make_float (f64.sqrt (call $as_float_co (local.get $a0)))))

  ;; Transcendentals all route through host_math with a kind index.
  (func $math_host1 (param $kind i32) (param $v anyref) (result anyref)
    (call $make_float (call $host_math (local.get $kind) (call $as_float_co (local.get $v)))))
  (func $math_via_host (param $kind i32) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $math_host1 (local.get $kind) (call $args_at (local.get $args) (i32.const 0)))))
  (func $builtin_math_sin  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 0) (local.get $args)))
  (func $builtin_math_sin_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $math_host1 (i32.const 0) (local.get $a0)))
  (func $builtin_math_cos  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 1) (local.get $args)))
  (func $builtin_math_cos_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $math_host1 (i32.const 1) (local.get $a0)))
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
          (call $as_float_co (call $args_at (local.get $args) (i32.const 0)))
          (call $as_float_co (call $args_at (local.get $args) (i32.const 1)))))))))
    (call $math_via_host (i32.const 5) (local.get $args)))
  (func $builtin_math_exp  (type $LuaFn) (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $math_via_host (i32.const 6) (local.get $args)))
  ;; math.log(x [, base]) — 1-arg: ln(x). 2-arg: log_base(x). Like reference
  ;; Lua, base 2 and 10 use log2/log10 (host kinds 8/9) for exact results;
  ;; any other base falls back to ln(x)/ln(base).
  (func $builtin_math_log (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $x f64) (local $base f64) (local $lx f64) (local $lb f64)
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then
        (local.set $x (call $as_float_co (call $args_at (local.get $args) (i32.const 0))))
        (local.set $base (call $as_float_co (call $args_at (local.get $args) (i32.const 1))))
        (if (f64.eq (local.get $base) (f64.const 2))
          (then (return (array.new_fixed $ArgArr 1 (call $make_float
            (call $host_math (i32.const 8) (local.get $x)))))))
        (if (f64.eq (local.get $base) (f64.const 10))
          (then (return (array.new_fixed $ArgArr 1 (call $make_float
            (call $host_math (i32.const 9) (local.get $x)))))))
        (local.set $lx (call $host_math (i32.const 7) (local.get $x)))
        (local.set $lb (call $host_math (i32.const 7) (local.get $base)))
        (return (array.new_fixed $ArgArr 1
          (call $make_float (f64.div (local.get $lx) (local.get $lb)))))))
    (call $math_via_host (i32.const 7) (local.get $args)))

  ;; math.fmod(x, y) — truncating remainder (rounds quotient toward zero).
  ;; Distinct from Lua's `%` operator (which is floor-modulo).
  ;; If both args are integers: integer result; y == 0 raises.
  ;; Otherwise: precise C fmod via the host (JS `%`); a WAT x-trunc(x/y)*y
  ;; cancels catastrophically for large |x| (e.g. fmod(1e308,255) -> 0).
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
          (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 455) (i32.const 24)) (i32.const 0)))))
        (return (array.new_fixed $ArgArr 1
          (call $make_int (i64.rem_s (call $as_int (local.get $a))
                                      (local.get $iy)))))))
    (local.set $fx (call $as_float_co (local.get $a)))
    (local.set $fy (call $as_float_co (local.get $b)))
    (array.new_fixed $ArgArr 1
      (call $make_float
        (call $host_math2 (i32.const 2) (local.get $fx) (local.get $fy)))))

  ;; math.modf(x) — returns (integral, fractional).
  ;; Integral part is returned as integer if it fits in i64, else as float.
  ;; Fractional part is always a float.
  (func $builtin_math_modf (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $x f64) (local $ip f64) (local $fp f64)
    (local $out (ref $ArgArr)) (local $head anyref)
    (local.set $x (call $as_float_co (call $args_at (local.get $args) (i32.const 0))))
    (local.set $ip (f64.trunc (local.get $x)))
    ;; Naive `x - ip` is NaN when x is ±inf (inf - inf). Reference Lua
    ;; (and IEEE-754 libm modf) returns ±0 for the fractional part when
    ;; x is infinite. For NaN we propagate NaN through both outputs.
    (if (f64.ne (local.get $ip) (local.get $ip))           ;; NaN
      (then (local.set $fp (local.get $x)))                ;; propagate NaN
      (else
        (if (f64.eq (f64.abs (local.get $ip)) (f64.const inf))
          (then (local.set $fp (f64.const 0)))
          (else (local.set $fp (f64.sub (local.get $x) (local.get $ip)))))))
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
    ;; Coerce a numeric-string argument first, like the other math.* fns.
    (call $need_arg (local.get $args) (i32.const 0))
    (local.set $v (call $coerce_num (call $args_at (local.get $args) (i32.const 0))))
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
    (call $need_arg (local.get $args) (i32.const 0))
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (call $is_int (local.get $v))
      (then (return (array.new_fixed $ArgArr 1
              (struct.new $LuaString
                (array.new_fixed $LuaArr 7
                  (i32.const 105) (i32.const 110) (i32.const 116)
                  (i32.const 101) (i32.const 103) (i32.const 101)
                  (i32.const 114)) (i32.const 0))))))
    (if (call $is_float (local.get $v))
      (then (return (array.new_fixed $ArgArr 1
              (struct.new $LuaString
                (array.new_fixed $LuaArr 5
                  (i32.const 102) (i32.const 108) (i32.const 111)
                  (i32.const 97)  (i32.const 116)) (i32.const 0))))))
    (array.new_fixed $ArgArr 1 (ref.null any)))

  ;; math.ult(m, n) — unsigned i64 less-than. Both args must be integers.
  (func $builtin_math_ult (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $lua_bool_to_ref
        (i64.lt_u
          (call $as_int_co (call $args_at (local.get $args) (i32.const 0)))
          (call $as_int_co (call $args_at (local.get $args) (i32.const 1)))))))

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
    (local.set $hi (call $as_int_co (call $args_at (local.get $args) (i32.const 0))))
    (local.set $lo (i64.const 1))
    (if (i32.gt_u (local.get $n) (i32.const 1))
      (then
        (local.set $lo (local.get $hi))
        (local.set $hi (call $as_int_co (call $args_at (local.get $args) (i32.const 1))))))
    ;; full-range mode: math.random(0)
    (if (i32.and (i32.eq (local.get $n) (i32.const 1))
                 (i64.eqz (local.get $hi)))
      (then (return (array.new_fixed $ArgArr 1
              (call $make_int (call $rng_next))))))
    (if (i64.gt_s (local.get $lo) (local.get $hi))
      (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 355) (i32.const 13)) (i32.const 0)))))
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
        (local.set $x (call $as_int_co (call $args_at (local.get $args) (i32.const 0))))
        (if (i32.gt_u (local.get $n) (i32.const 1))
          (then (local.set $y (call $as_int_co (call $args_at (local.get $args) (i32.const 1)))))
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
        (f64.mul (call $as_float_co (call $args_at (local.get $args) (i32.const 0)))
                 (f64.const 57.29577951308232)))))   ;; 180 / pi

  ;; math.rad(x) — degrees to radians.
  (func $builtin_math_rad (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $make_float
        (f64.mul (call $as_float_co (call $args_at (local.get $args) (i32.const 0)))
                 (f64.const 0.017453292519943295))))) ;; pi / 180

  (func $math_ceil (param $v anyref) (result anyref)
    (if (call $is_int (local.get $v)) (then (return (local.get $v))))
    (call $f64_to_int_result (f64.ceil (call $as_float_co (local.get $v)))))
  (func $builtin_math_ceil (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $math_ceil (call $args_at (local.get $args) (i32.const 0)))))
  (func $builtin_math_ceil_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $math_ceil (local.get $a0)))

  ;; math.min/max: pick the smaller/larger of args[0..n-1] using $num_lt.
  (func $builtin_math_min (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $best anyref) (local $v anyref)
    (call $need_arg (local.get $args) (i32.const 0))
    (local.set $n (array.len (local.get $args)))
    (local.set $best (call $args_at (local.get $args) (i32.const 0)))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $v (call $args_at (local.get $args) (local.get $i)))
      (if (call $lua_lt_raw (local.get $v) (local.get $best))
        (then (local.set $best (local.get $v))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (local.get $best)))
  ;; The fast entries of min/max: up to four arguments, the same comparisons
  ;; in the same order.
  (func $builtin_math_min_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (local $best anyref)
    (if (i32.eqz (local.get $n)) (then (call $throw_lit (i32.const 620) (i32.const 14))))   ;; "value expected"
    (local.set $best (local.get $a0))
    (if (i32.gt_s (local.get $n) (i32.const 1))
      (then (if (call $lua_lt_raw (local.get $a1) (local.get $best)) (then (local.set $best (local.get $a1))))))
    (if (i32.gt_s (local.get $n) (i32.const 2))
      (then (if (call $lua_lt_raw (local.get $a2) (local.get $best)) (then (local.set $best (local.get $a2))))))
    (if (i32.gt_s (local.get $n) (i32.const 3))
      (then (if (call $lua_lt_raw (local.get $a3) (local.get $best)) (then (local.set $best (local.get $a3))))))
    (local.get $best))
  (func $builtin_math_max_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (local $best anyref)
    (if (i32.eqz (local.get $n)) (then (call $throw_lit (i32.const 620) (i32.const 14))))   ;; "value expected"
    (local.set $best (local.get $a0))
    (if (i32.gt_s (local.get $n) (i32.const 1))
      (then (if (call $lua_lt_raw (local.get $best) (local.get $a1)) (then (local.set $best (local.get $a1))))))
    (if (i32.gt_s (local.get $n) (i32.const 2))
      (then (if (call $lua_lt_raw (local.get $best) (local.get $a2)) (then (local.set $best (local.get $a2))))))
    (if (i32.gt_s (local.get $n) (i32.const 3))
      (then (if (call $lua_lt_raw (local.get $best) (local.get $a3)) (then (local.set $best (local.get $a3))))))
    (local.get $best))

  (func $builtin_math_max (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $best anyref) (local $v anyref)
    (call $need_arg (local.get $args) (i32.const 0))
    (local.set $n (array.len (local.get $args)))
    (local.set $best (call $args_at (local.get $args) (i32.const 0)))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $v (call $args_at (local.get $args) (local.get $i)))
      (if (call $lua_lt_raw (local.get $best) (local.get $v))
        (then (local.set $best (local.get $v))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (local.get $best)))
