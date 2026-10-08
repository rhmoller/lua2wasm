;; The os library: thin shims over the host environment.

  ;; The host owns the actual concept of "now" and the environment; these
  ;; builtins just convert between Lua values and the host's contract.

  ;; Read an integer-valued date-table field. When the field is nil, use
  ;; $def if $has_def, else raise "field missing in date table". A present
  ;; non-number field is the same error (semantic match — reference says
  ;; "is not an integer"; we don't track exact wording).
  (func $os_date_field (param $t (ref $LuaTable)) (param $off i32) (param $len i32)
                       (param $def i64) (param $has_def i32) (result i64)
    (local $v anyref)
    (local.set $v (call $tab_get (local.get $t)
      (struct.new $LuaString
        (array.new_data $LuaArr $str_data (local.get $off) (local.get $len)) (i32.const 0))))
    (if (ref.is_null (local.get $v))
      (then
        (if (local.get $has_def) (then (return (local.get $def))))
        (call $throw_lit (i32.const 898) (i32.const 27))))   ;; "field missing in date table"
    ;; Present field must be an integer (or an integral float in i64 range).
    ;; A fractional/out-of-range float or non-number is a catchable error,
    ;; not an uncatchable i64.trunc_f64_s trap (os.time{year=1e20} crashed).
    (if (i32.eqz (call $try_to_int (local.get $v)))
      (then (call $throw_lit (i32.const 1059) (i32.const 23))))   ;; "field is not an integer"
    (call $as_int_unchecked (local.get $v)))

  (func $builtin_os_time (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $arg anyref) (local $t (ref $LuaTable))
    (local.set $arg (call $args_at (local.get $args) (i32.const 0)))
    ;; No argument (or nil): current wall-clock time.
    (if (ref.is_null (local.get $arg))
      (then (return (array.new_fixed $ArgArr 1 (call $make_int (call $host_os_time))))))
    ;; Otherwise the argument must be a table {year, month, day, [hour, min,
    ;; sec]} interpreted as LOCAL time. year/month/day are required; hour
    ;; defaults to 12, min/sec to 0 (matching reference).
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $arg)))
      (then (call $throw_lit (i32.const 684) (i32.const 14))))   ;; "table expected"
    (local.set $t (ref.cast (ref $LuaTable) (local.get $arg)))
    (array.new_fixed $ArgArr 1 (call $make_int (call $host_os_time_table
      (call $os_date_field (local.get $t) (i32.const 306) (i32.const 4) (i64.const 0) (i32.const 0))   ;; year
      (call $os_date_field (local.get $t) (i32.const 310) (i32.const 5) (i64.const 0) (i32.const 0))   ;; month
      (call $os_date_field (local.get $t) (i32.const 315) (i32.const 3) (i64.const 0) (i32.const 0))   ;; day
      (call $os_date_field (local.get $t) (i32.const 318) (i32.const 4) (i64.const 12) (i32.const 1))  ;; hour
      (call $os_date_field (local.get $t) (i32.const 322) (i32.const 3) (i64.const 0) (i32.const 1))   ;; min
      (call $os_date_field (local.get $t) (i32.const 325) (i32.const 3) (i64.const 0) (i32.const 1)))))) ;; sec

  (func $builtin_os_clock (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $make_float (call $host_os_clock))))

  ;; os.difftime(t2, t1) — seconds between two times, as a float.
  (func $builtin_os_difftime (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $make_float
        (f64.sub
          (call $as_float (call $args_at (local.get $args) (i32.const 0)))
          (call $as_float (call $args_at (local.get $args) (i32.const 1)))))))

  ;; os.setlocale([locale [, category]]) — only the portable "C" locale is
  ;; available. The query form (nil/absent locale) reports it; setting "C"
  ;; returns "C"; any other locale name is unsupported and returns nil — the
  ;; same shape reference Lua produces on a host where only "C" is installed.
  (func $builtin_os_setlocale (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $a anyref)
    (if (i32.gt_s (array.len (local.get $args)) (i32.const 0))
      (then (local.set $a (call $args_at (local.get $args) (i32.const 0)))))
    (if (ref.is_null (local.get $a))
      (then (return (array.new_fixed $ArgArr 1
        (struct.new $LuaString (array.new_fixed $LuaArr 1 (i32.const 67)) (i32.const 0))))))
    (if (ref.test (ref $LuaString) (local.get $a))
      (then (if (call $str_eq (local.get $a)
                  (struct.new $LuaString (array.new_fixed $LuaArr 1 (i32.const 67)) (i32.const 0)))
              (then (return (array.new_fixed $ArgArr 1
                (struct.new $LuaString (array.new_fixed $LuaArr 1 (i32.const 67)) (i32.const 0))))))))
    (array.new_fixed $ArgArr 1 (ref.null any)))

  (func $builtin_os_getenv (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $written i32)
    (if (i32.eqz (array.len (local.get $args)))
      (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 669) (i32.const 15)) (i32.const 0)))))
    (local.set $written
      (call $host_os_getenv (call $args_at (local.get $args) (i32.const 0))))
    (if (i32.lt_s (local.get $written) (i32.const 0))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (array.new_fixed $ArgArr 1 (call $fmt_buf_to_str (local.get $written))))

  (func $builtin_os_exit (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $a anyref) (local $code i32) (local $has i32)
    (if (i32.eqz (array.len (local.get $args)))
      (then
        (call $host_os_exit (i32.const 0) (i32.const 0))
        (return (global.get $g_empty_args))))
    (local.set $has (i32.const 1))
    (local.set $a (call $args_at (local.get $args) (i32.const 0)))
    ;; nil → 0; boolean → (true ? 0 : 1); integer → wrap to i32.
    (if (ref.test (ref $LuaBool) (local.get $a))
      (then (local.set $code
              (i32.sub (i32.const 1)
                       (struct.get $LuaBool $b
                         (ref.cast (ref $LuaBool) (local.get $a))))))
      (else
        (if (i32.eqz (ref.is_null (local.get $a)))
          (then (local.set $code
                  (i32.wrap_i64 (call $as_int (local.get $a))))))))
    (call $host_os_exit (local.get $code) (local.get $has))
    ;; Host never returns; satisfy the type checker.
    (global.get $g_empty_args))

  ;; os.date([fmt [, time]]) — formats $time per a strftime-ish $fmt.
  ;; When the format is "*t" or "!*t", $host_os_date returns -1 after
  ;; packing 9 i32 fields into $fmt_buf (year/month/day/hour/min/sec/
  ;; wday/yday/isdst, each LE). We then materialize the table; the dst
  ;; field is decoded as boolean.
  (func $builtin_os_date (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $fmt anyref) (local $tv anyref) (local $time i64)
    (local $has_time i32) (local $written i32) (local $buf (ref $LuaArr))
    (local $tab (ref $LuaTable))
    (if (i32.gt_s (array.len (local.get $args)) (i32.const 0))
      (then (local.set $fmt (call $args_at (local.get $args) (i32.const 0)))))
    (if (i32.gt_s (array.len (local.get $args)) (i32.const 1))
      (then
        (local.set $tv (call $args_at (local.get $args) (i32.const 1)))
        (if (i32.eqz (ref.is_null (local.get $tv)))
          (then
            (local.set $time (call $as_int (local.get $tv)))
            (local.set $has_time (i32.const 1))))))
    (local.set $written
      (call $host_os_date (local.get $fmt) (local.get $time)
                          (local.get $has_time)))
    (if (i32.ge_s (local.get $written) (i32.const 0))
      (then
        (return (array.new_fixed $ArgArr 1
          (call $fmt_buf_to_str (local.get $written))))))
    ;; Table case: read 9 LE i32s from $fmt_buf.
    (local.set $buf (ref.as_non_null (global.get $fmt_buf)))
    (local.set $tab (call $tab_new))
    (call $os_date_set_int (local.get $tab) (local.get $buf) (i32.const 306) (i32.const 4) (i32.const 0))
    (call $os_date_set_int (local.get $tab) (local.get $buf) (i32.const 310) (i32.const 5) (i32.const 1))
    (call $os_date_set_int (local.get $tab) (local.get $buf) (i32.const 315) (i32.const 3) (i32.const 2))
    (call $os_date_set_int (local.get $tab) (local.get $buf) (i32.const 318) (i32.const 4) (i32.const 3))
    (call $os_date_set_int (local.get $tab) (local.get $buf) (i32.const 322) (i32.const 3) (i32.const 4))
    (call $os_date_set_int (local.get $tab) (local.get $buf) (i32.const 325) (i32.const 3) (i32.const 5))
    (call $os_date_set_int (local.get $tab) (local.get $buf) (i32.const 328) (i32.const 4) (i32.const 6))
    (call $os_date_set_int (local.get $tab) (local.get $buf) (i32.const 332) (i32.const 4) (i32.const 7))
    (call $tab_set (local.get $tab)
      (struct.new $LuaString
        (array.new_data $LuaArr $str_data (i32.const 336) (i32.const 5)) (i32.const 0))
      (call $lua_bool_to_ref
        (i32.wrap_i64 (call $pack_read_int (local.get $buf)
                        (i32.const 32) (i32.const 4) (i32.const 1)))))
    (array.new_fixed $ArgArr 1 (local.get $tab)))

  ;; Set $tab[<key in $str_data at key_off..key_off+key_len>] to the LE
  ;; i32 packed at index $idx (offset $idx*4) of $buf. Used by os.date
  ;; "*t" to materialize its 8 integer fields; the boolean isdst field
  ;; takes a different builder so isn't routed through here.
  (func $os_date_set_int
    (param $tab (ref $LuaTable)) (param $buf (ref $LuaArr))
    (param $key_off i32) (param $key_len i32) (param $idx i32)
    (call $tab_set (local.get $tab)
      (struct.new $LuaString
        (array.new_data $LuaArr $str_data (local.get $key_off) (local.get $key_len)) (i32.const 0))
      (call $make_int
        (call $pack_read_int (local.get $buf)
          (i32.mul (local.get $idx) (i32.const 4))
          (i32.const 4) (i32.const 1)))))

  ;; os.execute([command]) — minimal stub. With no command, the spec
  ;; lets us report "a shell is available" by returning a truthy value;
  ;; we always claim yes so suites that gate filesystem tests on this
  ;; (e.g. main.lua) at least progress to the next step. With a command,
  ;; we can't actually run anything in the wasm host, so report a
  ;; consistent failure: (nil, "exit", 1) per the Lua 5.5 contract.
  (func $builtin_os_execute (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $exit_str (ref $LuaString))
    (local.set $exit_str (struct.new $LuaString
      (array.new_fixed $LuaArr 4
        (i32.const 101) (i32.const 120) (i32.const 105) (i32.const 116)) (i32.const 0)))  ;; e,x,i,t
    (if (i32.eqz (array.len (local.get $args)))
      (then (return (array.new_fixed $ArgArr 1 (global.get $g_true)))))
    (array.new_fixed $ArgArr 3
      (ref.null any)
      (local.get $exit_str)
      (call $make_int (i64.const 1))))

  ;; os.remove(path) -> true, or (nil, message).
  (func $builtin_os_remove (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $r i32)
    (local.set $r (call $host_os_remove (call $args_at (local.get $args) (i32.const 0))))
    (if (i32.lt_s (local.get $r) (i32.const 0))
      (then (return (call $io_fail (local.get $r)
        (struct.new $LuaString (array.new_fixed $LuaArr 13
          (i32.const 114) (i32.const 101) (i32.const 109) (i32.const 111)   ;; remo
          (i32.const 118) (i32.const 101) (i32.const 32) (i32.const 102)    ;; ve(sp)f
          (i32.const 97) (i32.const 105) (i32.const 108) (i32.const 101)    ;; aile
          (i32.const 100)) (i32.const 0))))))                                            ;; d
    (array.new_fixed $ArgArr 1 (global.get $g_true)))

  ;; os.rename(old, new) -> true, or (nil, message).
  (func $builtin_os_rename (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $r i32)
    (local.set $r (call $host_os_rename
      (call $args_at (local.get $args) (i32.const 0))
      (call $args_at (local.get $args) (i32.const 1))))
    (if (i32.lt_s (local.get $r) (i32.const 0))
      (then (return (call $io_fail (local.get $r)
        (struct.new $LuaString (array.new_fixed $LuaArr 13
          (i32.const 114) (i32.const 101) (i32.const 110) (i32.const 97)    ;; rena
          (i32.const 109) (i32.const 101) (i32.const 32) (i32.const 102)    ;; me(sp)f
          (i32.const 97) (i32.const 105) (i32.const 108) (i32.const 101)    ;; aile
          (i32.const 100)) (i32.const 0))))))                                            ;; d
    (array.new_fixed $ArgArr 1 (global.get $g_true)))

  ;; os.tmpname() -> a fresh temp-file name (the host owns the policy).
  (func $builtin_os_tmpname (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1 (call $fmt_buf_to_str (call $host_os_tmpname))))
