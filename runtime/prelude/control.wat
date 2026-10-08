;; Statement support: the numeric for loop (prep, limit, overflow) and
;; to-be-closed variables.

  ;; --- numeric-for helper ---
  (func $for_step_positive (param $s anyref) (result i32)
    (if (result i32) (call $is_int (local.get $s))
      (then (i64.ge_s (call $as_int (local.get $s)) (i64.const 0)))
      (else (f64.ge (call $as_float (local.get $s)) (f64.const 0)))))

  ;; Raise "bad 'for' <what> (number expected, got <type>)" at the loop's own
  ;; line. $off/$len address the "bad 'for' <what> (" prefix in the slab.
  (func $for_error (param $v anyref) (param $off i32) (param $len i32) (param $line i32)
    (throw $LuaError (call $prefix_error_msg
      (ref.as_non_null (global.get $g_src_name))
      (local.get $line)
      (ref.cast (ref $LuaString) (call $lua_concat
        (call $lua_concat
          (struct.new $LuaString
            (array.new_data $LuaArr $str_data (local.get $off) (local.get $len)) (i32.const 0))
          (struct.new $LuaString
            (array.new_data $LuaArr $str_data (i32.const 950) (i32.const 21)) (i32.const 0)))
        (call $lua_concat
          (struct.new $LuaString (call $basic_type_bytes (local.get $v)) (i32.const 0))
          (struct.new $LuaString
            (array.new_data $LuaArr $str_data (i32.const 1207) (i32.const 1)) (i32.const 0))))))))

  ;; The limit of an integer numeric-for (Lua's forlimit): any value is
  ;; accepted as long as it converts to a number (numeric strings included).
  ;; A float limit is floored (ceiled for a negative step); one beyond the i64
  ;; range clips to maxinteger/mininteger, or skips the loop when the init
  ;; can't reach it. NaN fails `0 < lim`, so it behaves like -inf (skips an
  ;; ascending loop, runs a descending one) — as in reference Lua. Returns the
  ;; i64 limit and whether to skip the loop.
  (func $for_limit (param $lim anyref) (param $init i64) (param $step i64) (param $line i32)
                   (result i64 i32)
    (local $c anyref) (local $f f64) (local $p i64)
    (local.set $c (call $coerce_num (local.get $lim)))
    (if (ref.is_null (local.get $c))
      (then (call $for_error (local.get $lim) (i32.const 1149) (i32.const 17) (local.get $line))))
    (if (call $is_int (local.get $c))
      (then (local.set $p (call $as_int (local.get $c))))
      (else
        (local.set $f (call $as_float (local.get $c)))
        (local.set $f (if (result f64) (i64.lt_s (local.get $step) (i64.const 0))
          (then (f64.ceil (local.get $f)))
          (else (f64.floor (local.get $f)))))
        (if (i32.and (f64.ge (local.get $f) (f64.const -9223372036854775808.0))
                     (f64.lt (local.get $f) (f64.const 9223372036854775808.0)))
          (then (local.set $p (i64.trunc_f64_s (local.get $f))))
          (else
            (if (f64.gt (local.get $f) (f64.const 0))
              (then
                (if (i64.lt_s (local.get $step) (i64.const 0))
                  (then (i64.const 0) (i32.const 1) (return)))
                (local.set $p (i64.const 9223372036854775807)))
              (else
                (if (i64.gt_s (local.get $step) (i64.const 0))
                  (then (i64.const 0) (i32.const 1) (return)))
                (local.set $p (i64.const -9223372036854775808))))))))
    (local.get $p)
    (if (result i32) (i64.gt_s (local.get $step) (i64.const 0))
      (then (i64.gt_s (local.get $init) (local.get $p)))
      (else (i64.lt_s (local.get $init) (local.get $p)))))

  ;; Lua's forprep over boxed control values, for the generic loop. Integer
  ;; init AND step (actual integers, not numeric strings) make an integer
  ;; loop with the limit settled by $for_limit; otherwise limit, step and init
  ;; are coerced to floats, checked in that order. A zero step raises before
  ;; the limit is looked at. Returns the normalized (init, limit, step) and
  ;; whether to skip the loop; the loop tests only later iterations, so a NaN
  ;; float bound runs the body once, as in reference Lua.
  (func $for_prep (param $init anyref) (param $lim anyref) (param $step anyref) (param $line i32)
                  (result anyref anyref anyref i32)
    (local $i i64) (local $s i64) (local $p i64) (local $skip i32)
    (local $c anyref) (local $fi f64) (local $fl f64) (local $fs f64)
    (if (i32.and (call $is_int (local.get $init)) (call $is_int (local.get $step)))
      (then
        (local.set $i (call $as_int (local.get $init)))
        (local.set $s (call $as_int (local.get $step)))
        (if (i64.eqz (local.get $s))
          (then (call $throw_lit_at (i32.const 75) (i32.const 18) (local.get $line))))
        (call $for_limit (local.get $lim) (local.get $i) (local.get $s) (local.get $line))
        (local.set $skip)
        (local.set $p)
        (local.get $init) (call $make_int (local.get $p)) (local.get $step) (local.get $skip)
        (return)))
    (local.set $c (call $coerce_num (local.get $lim)))
    (if (ref.is_null (local.get $c))
      (then (call $for_error (local.get $lim) (i32.const 1149) (i32.const 17) (local.get $line))))
    (local.set $fl (call $as_float (local.get $c)))
    (local.set $c (call $coerce_num (local.get $step)))
    (if (ref.is_null (local.get $c))
      (then (call $for_error (local.get $step) (i32.const 1166) (i32.const 16) (local.get $line))))
    (local.set $fs (call $as_float (local.get $c)))
    (local.set $c (call $coerce_num (local.get $init)))
    (if (ref.is_null (local.get $c))
      (then (call $for_error (local.get $init) (i32.const 1182) (i32.const 25) (local.get $line))))
    (local.set $fi (call $as_float (local.get $c)))
    (if (f64.eq (local.get $fs) (f64.const 0))
      (then (call $throw_lit_at (i32.const 75) (i32.const 18) (local.get $line))))
    (call $make_float (local.get $fi))
    (call $make_float (local.get $fl))
    (call $make_float (local.get $fs))
    (if (result i32) (f64.gt (local.get $fs) (f64.const 0))
      (then (f64.lt (local.get $fl) (local.get $fi)))
      (else (f64.lt (local.get $fi) (local.get $fl)))))

  ;; True iff advancing a numeric-for index wrapped the i64 range: only
  ;; possible when index and step are both integers. step>0 wraps iff
  ;; next < index; step<0 wraps iff next > index. Float loops never wrap
  ;; (they reach +/-inf, which fails the <= test and terminates normally).
  (func $for_overflowed (param $i anyref) (param $step anyref) (param $next anyref)
                        (result i32)
    (if (i32.eqz (i32.and (call $is_int (local.get $i)) (call $is_int (local.get $step))))
      (then (return (i32.const 0))))
    (if (i64.gt_s (call $as_int (local.get $step)) (i64.const 0))
      (then (return (i64.lt_s (call $as_int (local.get $next))
                              (call $as_int (local.get $i))))))
    (i64.gt_s (call $as_int (local.get $next)) (call $as_int (local.get $i))))

  ;; --- to-be-closed variables ---
  ;; To-be-closed (<close>) variables are tracked on a per-activation $Tbc
  ;; stack: $tbc_push validates and records at the declaration, $close_upto
  ;; runs __close on every scope exit. $g_mkey_close is emitted by codegen
  ;; alongside the other $g_mkey_* keys.

  ;; Validate a value bound to a <close> variable, at the declaration site.
  ;; nil and false are accepted (and never closed); any other value must have
  ;; a __close metamethod, else raise "variable got a non-closable value" —
  ;; matching reference Lua, which rejects at the declaration, not at scope exit.
  (func $check_closable (param $v anyref)
    (if (ref.is_null (local.get $v)) (then (return)))
    (if (i32.eqz (call $lua_truthy (local.get $v))) (then (return)))
    (if (ref.is_null (call $get_metamethod (local.get $v)
                       (ref.as_non_null (global.get $g_mkey_close))))
      (then (call $throw_lit (i32.const 1082) (i32.const 33)))))

  ;; Append a value to the to-be-closed stack after validating it at the
  ;; declaration (nil/false accepted and stored, but never closed).
  (func $tbc_push (param $tbc (ref $Tbc)) (param $v anyref)
    (local $n i32)
    (call $check_closable (local.get $v))
    (local.set $n (struct.get $Tbc $len (local.get $tbc)))
    (array.set $ArgArr (struct.get $Tbc $items (local.get $tbc))
      (local.get $n) (local.get $v))
    (struct.set $Tbc $len (local.get $tbc) (i32.add (local.get $n) (i32.const 1))))

  ;; Close every to-be-closed value above $target, innermost first. The stack
  ;; pops as it goes, so any later pass over an already-closed entry is a no-op
  ;; (this is what makes a return/break/goto close and the function-level error
  ;; catch idempotent — whichever runs first does the work). $errobj is the
  ;; in-flight error (null on a normal exit); it is passed as __close's 2nd
  ;; argument and replaced if a __close itself raises, so a later close sees the
  ;; newest error and the newest error is what finally (re)propagates. Remaining
  ;; closes still run after one raises. call_depth is re-pinned to the entry
  ;; depth around each __close so an error unwind doesn't run them at an inflated
  ;; depth (which would trip the stack-overflow guard).
  (func $close_upto (param $tbc (ref $Tbc)) (param $target i32) (param $errobj anyref)
    (local $items (ref $ArgArr))
    (local $i i32)
    (local $v anyref)
    (local $pending anyref)
    (local $depth i32) (local $cost_saved i32)
    (local.set $items (struct.get $Tbc $items (local.get $tbc)))
    (local.set $pending (local.get $errobj))
    (local.set $depth (global.get $call_depth))
    (local.set $cost_saved (global.get $stack_cost))
    (block $done
      (loop $L
        (local.set $i (struct.get $Tbc $len (local.get $tbc)))
        (br_if $done (i32.le_s (local.get $i) (local.get $target)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (local.set $v (array.get $ArgArr (local.get $items) (local.get $i)))
        (struct.set $Tbc $len (local.get $tbc) (local.get $i))   ;; pop before close
        (if (call $lua_truthy (local.get $v))
          (then
            (global.set $call_depth (local.get $depth))
            (global.set $stack_cost (local.get $cost_saved))
            (block $eldone
              (block $elcatch (result anyref)
                (try_table (catch $LuaError $elcatch)
                  (drop (call $lua_call_any
                    (call $get_metamethod (local.get $v)
                      (ref.as_non_null (global.get $g_mkey_close)))
                    (array.new_fixed $ArgArr 2 (local.get $v) (local.get $pending))
                    (i32.const 0))))
                (br $eldone))   ;; success: skip the catch handler
              ;; reached only via catch: pending = the raised error
              (local.set $pending))))
        (br $L)))
    (global.set $call_depth (local.get $depth))
            (global.set $stack_cost (local.get $cost_saved))
    (if (i32.eqz (ref.is_null (local.get $pending)))
      (then (throw $LuaError (local.get $pending)))))
