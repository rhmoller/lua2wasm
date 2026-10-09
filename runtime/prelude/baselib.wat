;; The base library: print, error, pcall, xpcall, warn, assert, the raw
;; accessors, select, type, tostring, tonumber, next, pairs, ipairs,
;; metatables, require, collectgarbage and load.

  ;; Remembered for collectgarbage's switch-and-return-previous spec
  ;; (0 = incremental, 1 = generational). Neither mode does any work.
  (global $g_gc_mode (mut i32) (i32.const 0))

  ;; --- _G: the global-environment table ---
  ;; Every Lua global (user-declared, library, builtin) is an entry in
  ;; this table. \$stdlib_init populates it; codegen emits \$tab_get /
  ;; \$tab_set against it for every global read/write.
  (global $g_globals (mut (ref null $LuaTable)) (ref.null $LuaTable))
  ;; Shared metatable for all strings: {__index = string}. Built lazily by
  ;; $get_string_mt the first time getmetatable() sees a string.
  (global $g_string_mt  (mut (ref null $LuaTable)) (ref.null $LuaTable))

  ;; Real-Lua print: tostring each arg, join with TAB, host prints with a
  ;; trailing newline. Zero args -> just a newline.
  (func $builtin_print (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $acc anyref)
    (local $bld (ref $Builder)) (local $sbytes (ref $LuaArr))
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
    ;; Accumulate once in a $Builder (O(total) bytes) instead of chaining
    ;; $lua_concat, which reallocates the whole prefix per arg -> O(n^2).
    (local.set $bld (call $builder_new))
    (local.set $sbytes (call $str_bytes
      (call $lua_tostring (call $args_at (local.get $args) (i32.const 0)))))
    (call $builder_append (local.get $bld) (local.get $sbytes)
      (i32.const 0) (array.len (local.get $sbytes)))
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (call $builder_append_byte (local.get $bld) (i32.const 9))   ;; TAB
      (local.set $sbytes (call $str_bytes
        (call $lua_tostring (call $args_at (local.get $args) (local.get $i)))))
      (call $builder_append (local.get $bld) (local.get $sbytes)
        (i32.const 0) (array.len (local.get $sbytes)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $host_print (call $builder_finish (local.get $bld)))
    (global.get $g_empty_args))

  (func $builtin_error (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $msg anyref) (local $level i32) (local $idx i32)
    (local.set $msg (call $args_at (local.get $args) (i32.const 0)))
    (local.set $level (i32.const 1))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (local.set $level (i32.wrap_i64
              (call $as_int
                (call $args_at (local.get $args) (i32.const 1)))))))
    ;; Prepend "<src>:<line>: " when msg is a string AND level > 0 AND
    ;; the requested frame exists. Same rule as reference Lua.
    (if (i32.gt_s (local.get $level) (i32.const 0))
      (then
        (if (ref.test (ref $LuaString) (local.get $msg))
          (then
            (local.set $idx (i32.sub (global.get $call_depth)
                                     (local.get $level)))
            (if (i32.ge_s (local.get $idx) (i32.const 0))
              (then (local.set $msg
                (call $prefix_error_msg
                  (ref.as_non_null (global.get $g_src_name))
                  (array.get $LineArr
                    (ref.as_non_null (global.get $call_lines))
                    (local.get $idx))
                  (ref.cast (ref $LuaString) (local.get $msg))))))))))
    (throw $LuaError (local.get $msg))
    ;; unreachable, but typechecker needs a tail expression:
    (global.get $g_empty_args))

  ;; Reference Lua's luaG_errormsg replaces a nil error object with the
  ;; string "<no error object>" before delivering it to the catcher (after
  ;; any message handler has run). error()/error(nil) raises a null anyref,
  ;; so mirror that substitution at the pcall/xpcall boundary.
  (func $err_or_noobj (param $e anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $e))
      (then (struct.new $LuaString
              (array.new_data $LuaArr $str_data (i32.const 768) (i32.const 17)) (i32.const 0)))
      (else (local.get $e))))

  ;; pcall(f, ...): calls f with the remaining args. Returns (true, results...)
  ;; on success; (false, err) on caught $LuaError. The callee can be any
  ;; value — we delegate to $lua_call_any, which walks __call and surfaces
  ;; a proper "attempt to call a non-function value" error when the chain
  ;; bottoms out, so pcall(non-function) returns (false, errmsg).
  (func $builtin_pcall (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $callee anyref) (local $f_args (ref $ArgArr))
    (local $n_total i32) (local $line i32)
    (local $err anyref) (local $results (ref $ArgArr)) (local $r2 (ref $ArgArr))
    (local $saved_depth i32) (local $cost_saved i32)
    (local.set $n_total (array.len (local.get $args)))
    (if (i32.eqz (local.get $n_total))
      (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 620) (i32.const 14)) (i32.const 0)))))
    (local.set $callee (array.get $ArgArr (local.get $args) (i32.const 0)))
    ;; f_args = args[1..]. $args_slice does the bulk copy with array.copy.
    (local.set $f_args (call $args_slice (local.get $args) (i32.const 1)))
    (local.set $saved_depth (global.get $call_depth))
    (local.set $cost_saved (global.get $stack_cost))
    ;; Pass the pcall call-site's line through to lua_call_any so error()
    ;; inside the callee reports the pcall(...) source position — matches
    ;; reference Lua, where pcall itself doesn't add a visible frame.
    (if (i32.gt_s (global.get $call_depth) (i32.const 0))
      (then (local.set $line (array.get $LineArr
        (ref.as_non_null (global.get $call_lines))
        (i32.sub (global.get $call_depth) (i32.const 1))))))
    (block $catch_err (result anyref)
      (local.set $results
        (try_table (result (ref $ArgArr)) (catch $LuaError $catch_err)
          (call $lua_call_any (local.get $callee) (local.get $f_args) (local.get $line))))
      (local.set $r2 (array.new $ArgArr (ref.null any)
        (i32.add (array.len (local.get $results)) (i32.const 1))))
      (array.set $ArgArr (local.get $r2) (i32.const 0) (global.get $g_true))
      (array.copy $ArgArr $ArgArr (local.get $r2) (i32.const 1)
        (local.get $results) (i32.const 0) (array.len (local.get $results)))
      (return (local.get $r2)))
    (local.set $err)
    (global.set $call_depth (local.get $saved_depth))
    (global.set $stack_cost (local.get $cost_saved))
    (array.new_fixed $ArgArr 2 (global.get $g_false)
      (call $err_or_noobj (local.get $err))))

  ;; xpcall(f, msgh, ...): like pcall, but on error calls msgh(err) and
  ;; uses its first return value as the error returned. If msgh itself
  ;; throws, the new error replaces the original.
  (func $builtin_xpcall (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $callee anyref) (local $msgh anyref) (local $f_args (ref $ArgArr))
    (local $n_total i32) (local $line i32)
    (local $err anyref) (local $results (ref $ArgArr)) (local $r2 (ref $ArgArr))
    (local $handled anyref) (local $saved_depth i32) (local $cost_saved i32)
    (local.set $n_total (array.len (local.get $args)))
    (if (i32.lt_s (local.get $n_total) (i32.const 2))
      (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 620) (i32.const 14)) (i32.const 0)))))
    (local.set $callee (array.get $ArgArr (local.get $args) (i32.const 0)))
    (local.set $msgh   (array.get $ArgArr (local.get $args) (i32.const 1)))
    ;; f_args = args[2..]. $args_slice does the bulk copy with array.copy.
    (local.set $f_args (call $args_slice (local.get $args) (i32.const 2)))
    (local.set $saved_depth (global.get $call_depth))
    (local.set $cost_saved (global.get $stack_cost))
    (if (i32.gt_s (global.get $call_depth) (i32.const 0))
      (then (local.set $line (array.get $LineArr
        (ref.as_non_null (global.get $call_lines))
        (i32.sub (global.get $call_depth) (i32.const 1))))))
    (block $catch_err (result anyref)
      (local.set $results
        (try_table (result (ref $ArgArr)) (catch $LuaError $catch_err)
          (call $lua_call_any (local.get $callee) (local.get $f_args) (local.get $line))))
      (local.set $r2 (array.new $ArgArr (ref.null any)
        (i32.add (array.len (local.get $results)) (i32.const 1))))
      (array.set $ArgArr (local.get $r2) (i32.const 0) (global.get $g_true))
      (array.copy $ArgArr $ArgArr (local.get $r2) (i32.const 1)
        (local.get $results) (i32.const 0) (array.len (local.get $results)))
      (return (local.get $r2)))
    (local.set $err)
    (global.set $call_depth (local.get $saved_depth))
    (global.set $stack_cost (local.get $cost_saved))
    (block $msgh_throw (result anyref)
      (local.set $handled (call $args_first
        (try_table (result (ref $ArgArr)) (catch $LuaError $msgh_throw)
          (call $lua_call_any (local.get $msgh)
            (array.new_fixed $ArgArr 1 (local.get $err)) (local.get $line)))))
      (return (array.new_fixed $ArgArr 2 (global.get $g_false)
        (call $err_or_noobj (local.get $handled)))))
    (local.set $handled)
    (global.set $call_depth (local.get $saved_depth))
    (global.set $stack_cost (local.get $cost_saved))
    (array.new_fixed $ArgArr 2 (global.get $g_false)
      (call $err_or_noobj (local.get $handled))))

  ;; warn(...): hand a concatenated string to the host. Accepts (and
  ;; silently ignores) the "@on"/"@off" control messages.
  (func $builtin_warn (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $n i32) (local $i i32) (local $first anyref)
    (local $bytes (ref $LuaArr))
    (local $bld (ref $Builder)) (local $wbytes (ref $LuaArr))
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
        (local.set $bytes (call $str_bytes
          (ref.cast (ref $LuaString) (local.get $first))))
        (if (i32.and (i32.ge_s (array.len (local.get $bytes)) (i32.const 1))
                     (i32.eq (array.get_u $LuaArr (local.get $bytes) (i32.const 0))
                             (i32.const 64)))   ;; '@'
          (then (return (global.get $g_empty_args))))))
    ;; Concatenate all args (each tostring'd) and hand to host_warn.
    ;; Single-pass $Builder accumulation (O(total) instead of O(n^2)).
    (local.set $bld (call $builder_new))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $wbytes (call $str_bytes
        (call $lua_tostring (call $args_at (local.get $args) (local.get $i)))))
      (call $builder_append (local.get $bld) (local.get $wbytes)
        (i32.const 0) (array.len (local.get $wbytes)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $host_warn (call $builder_finish (local.get $bld)))
    (global.get $g_empty_args))

  ;; --- assert, raw access, select ---
  (func $builtin_assert (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $msg anyref) (local $idx i32)
    (if (call $lua_truthy (call $args_at (local.get $args) (i32.const 0)))
      (then (return (local.get $args))))
    ;; failed: prefix string messages with "<src>:<assert-call-line>: "
    ;; — same shape as error(msg) at level 1 (assert is "error(msg,2)"
    ;; conceptually, but from our frame stack's POV the assert call
    ;; site is the topmost frame).
    (local.set $msg (call $args_at (local.get $args) (i32.const 1)))
    ;; Default message when none given (per Lua spec): "assertion failed!"
    (if (ref.is_null (local.get $msg))
      (then
        ;; "assertion failed!" — built in one shot rather than 17 array.set.
        ;; (Not in codegen's $str_data slab, which it owns; we keep our own
        ;; byte literal here.)
        (local.set $msg (struct.new $LuaString (array.new_fixed $LuaArr 17
          (i32.const 97)  (i32.const 115) (i32.const 115) (i32.const 101)   ;; asse
          (i32.const 114) (i32.const 116) (i32.const 105) (i32.const 111)   ;; rtio
          (i32.const 110) (i32.const 32)  (i32.const 102) (i32.const 97)    ;; n(sp)fa
          (i32.const 105) (i32.const 108) (i32.const 101) (i32.const 100)   ;; iled
          (i32.const 33)) (i32.const 0)))))                                               ;; !
    (if (ref.test (ref $LuaString) (local.get $msg))
      (then
        (local.set $idx (i32.sub (global.get $call_depth) (i32.const 1)))
        (if (i32.ge_s (local.get $idx) (i32.const 0))
          (then (local.set $msg
            (call $prefix_error_msg
              (ref.as_non_null (global.get $g_src_name))
              (array.get $LineArr
                (ref.as_non_null (global.get $call_lines))
                (local.get $idx))
              (ref.cast (ref $LuaString) (local.get $msg))))))))
    (throw $LuaError (local.get $msg))
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
                  (call $str_length (ref.cast (ref $LuaString) (local.get $v)))))))))))
    (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 698) (i32.const 24)) (i32.const 0)))
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
      (then (call $throw_lit (i32.const 237) (i32.const 24))))   ;; "attempt to index a value"
    (if (ref.is_null (local.get $k))
      (then (call $throw_lit (i32.const 261) (i32.const 18))))   ;; "table index is nil"
    ;; NaN check: a float key whose value != itself.
    (if (call $is_float (local.get $k))
      (then
        (local.set $f (call $as_float (local.get $k)))
        (if (f64.ne (local.get $f) (local.get $f))
          (then (call $throw_lit (i32.const 279) (i32.const 18))))))   ;; "table index is NaN"
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
      (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 684) (i32.const 14)) (i32.const 0)))))
    (array.new_fixed $ArgArr 1
      (call $tab_get_raw
        (ref.cast (ref $LuaTable) (local.get $t))
        (call $args_at (local.get $args) (i32.const 1)))))

  ;; rawequal(a, b): equality without consulting __eq.
  (func $builtin_rawequal (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $need_arg (local.get $args) (i32.const 1))
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
    (if (i32.eqz (local.get $n)) (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 620) (i32.const 14)) (i32.const 0)))))
    (local.set $sel (call $args_at (local.get $args) (i32.const 0)))
    (if (ref.test (ref $LuaString) (local.get $sel))
      (then
        (local.set $bytes (call $str_bytes
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
      (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 155) (i32.const 18)) (i32.const 0)))))
    (call $args_slice (local.get $args) (local.get $idx)))

  (func $builtin_type (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    ;; type() with no args is a `bad argument #1` error per the spec, not
    ;; an implicit nil. assert(not pcall(type)) in the upstream suite
    ;; relies on this.
    (if (i32.eqz (array.len (local.get $args)))
      (then (throw $LuaError (call $prefix_error_msg
        (ref.as_non_null (global.get $g_src_name))
        (if (result i32) (i32.gt_s (global.get $call_depth) (i32.const 0))
          (then (array.get $LineArr
                  (ref.as_non_null (global.get $call_lines))
                  (i32.sub (global.get $call_depth) (i32.const 1))))
          (else (i32.const 0)))
        (struct.new $LuaString
          (array.new_data $LuaArr $str_data
            (i32.const 93) (i32.const 36)) (i32.const 0))))))
    ;; type() ignores __name (it reports the basic type); $objtypename, used
    ;; by tostring and error messages, is the __name-aware variant.
    (array.new_fixed $ArgArr 1 (call $basic_type_name (call $args_at (local.get $args) (i32.const 0)))))

  ;; type()'s fast entry: no argument is the generic entry's error.
  (func $builtin_type_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (if (i32.eqz (local.get $n))
      (then (return (call $args_first (call $builtin_type (local.get $self) (global.get $g_empty_args))))))
    (call $basic_type_name (local.get $a0)))

  (func $builtin_tostring (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $need_arg (local.get $args) (i32.const 0))
    (array.new_fixed $ArgArr 1
      (call $lua_tostring (call $args_at (local.get $args) (i32.const 0)))))
  (func $builtin_tostring_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (if (i32.eqz (local.get $n)) (then (call $throw_lit (i32.const 620) (i32.const 14))))   ;; "value expected"
    (call $lua_tostring (local.get $a0)))

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
    (local $arg1 anyref) (local $has_base i32)
    (call $need_arg (local.get $args) (i32.const 0))
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (local.set $nargs (array.len (local.get $args)))
    ;; A nil second argument means "standard conversion", same as omitting it.
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then
        (local.set $arg1 (call $args_at (local.get $args) (i32.const 1)))
        (if (i32.eqz (ref.is_null (local.get $arg1)))
          (then
            (local.set $has_base (i32.const 1))
            (local.set $base (i32.wrap_i64 (call $as_int (local.get $arg1))))))))
    ;; No base: numbers pass through; strings parse with auto base detection.
    (if (i32.eqz (local.get $has_base))
      (then
        (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
          (then (return (array.new_fixed $ArgArr 1 (local.get $v)))))
        (if (i32.eqz (ref.test (ref $LuaString) (local.get $v)))
          (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
        (return (array.new_fixed $ArgArr 1
          (call $host_parse_num (local.get $v) (i32.const 0))))))
    ;; Explicit base must be in [2, 36] (reference raises "base out of range").
    (if (i32.or (i32.lt_s (local.get $base) (i32.const 2))
                (i32.gt_s (local.get $base) (i32.const 36)))
      (then (call $throw_lit (i32.const 820) (i32.const 17))))   ;; "base out of range"
    ;; With an explicit base, only strings are parsed; non-strings yield nil.
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $v)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (array.new_fixed $ArgArr 1
      (call $host_parse_num (local.get $v) (local.get $base))))

  ;; next(t, k): returns next key/value pair, or nothing when exhausted.
  (func $builtin_next (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $k anyref)
    (local $idx i32) (local $n i32) (local $alen i32)
    (local $val i64) (local $ok i32) (local $vals (ref null $TArr))
    (local.set $t (call $arg_table (call $args_at (local.get $args) (i32.const 0))))
    (local.set $k (call $args_at (local.get $args) (i32.const 1)))
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    ;; Iterate the array part (keys 1..alen, skipping holes) first, then the
    ;; hash part. Each "go to hash" path sets $idx to the hash start position
    ;; and falls out.
    (block $hash_phase
      (block $scan_array
        (if (ref.is_null (local.get $k))
          (then (local.set $idx (i32.const 0)) (br $scan_array)))
        (call $as_arr_key (local.get $k))
        (local.set $ok)
        (local.set $val)
        (if (i32.and (local.get $ok) (i64.ge_s (local.get $val) (i64.const 1)))
          (then
            (if (i64.le_s (local.get $val) (i64.extend_i32_s (local.get $alen)))
              (then (local.set $idx (i32.wrap_i64 (local.get $val))) (br $scan_array)))
            ;; A key inside the array's capacity but past $alen was trimmed off
            ;; the end (its value cleared during this traversal): the array is
            ;; exhausted. Like reference Lua, any key within the array part's
            ;; size is a valid position.
            (if (i32.eqz (ref.is_null (struct.get $LuaTable $arr (local.get $t))))
              (then (if (i64.le_s (local.get $val) (i64.extend_i32_s (array.len
                          (ref.as_non_null (struct.get $LuaTable $arr (local.get $t))))))
                (then (if (i32.lt_s (call $tab_find (local.get $t) (local.get $k)) (i32.const 0))
                  (then (local.set $idx (i32.const 0)) (br $hash_phase)))))))))
        ;; $k is a hash-part key. A key that was never inserted is invalid for
        ;; next() — raise rather than silently restarting iteration from the
        ;; first hash entry (reference luaH_next).
        (local.set $idx (call $tab_find (local.get $t) (local.get $k)))
        (if (i32.lt_s (local.get $idx) (i32.const 0))
          (then (call $throw_lit (i32.const 1021) (i32.const 21))))   ;; "invalid key to 'next'"
        (local.set $idx (i32.add (local.get $idx) (i32.const 1)))
        (br $hash_phase))
      ;; Scan the array part from slot $idx for the next non-hole.
      (block $array_done
        (loop $scan
          (br_if $array_done (i32.ge_s (local.get $idx) (local.get $alen)))
          (if (i32.eqz (ref.is_null (array.get $TArr (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
                                                   (local.get $idx))))
            (then (return (array.new_fixed $ArgArr 2
              (call $make_int (i64.add (i64.extend_i32_s (local.get $idx)) (i64.const 1)))
              (call $tval (array.get $TArr (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
                                           (local.get $idx))
                          (struct.get $LuaTable $farr (local.get $t)) (local.get $idx))))))
          (local.set $idx (i32.add (local.get $idx) (i32.const 1)))
          (br $scan)))
      (local.set $idx (i32.const 0)))
    (local.set $n (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t))))
    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
    ;; Skip lazily-deleted entries (value cleared to nil), so a key removed
    ;; mid-traversal is resumed past rather than mistaken for a live entry.
    (block $found
      (loop $scan
        (br_if $found (i32.ge_s (local.get $idx) (local.get $n)))
        (br_if $found (i32.eqz (ref.is_null (array.get $TArr
          (ref.as_non_null (local.get $vals)) (local.get $idx)))))
        (local.set $idx (i32.add (local.get $idx) (i32.const 1)))
        (br $scan)))
    ;; Exhausted: return an explicit nil (so `next({})` yields nil, not no
    ;; value). The generic-for loop stops on a nil first result either way.
    (if (i32.ge_s (local.get $idx) (local.get $n))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (array.new_fixed $ArgArr 2
      (array.get $TArr (struct.get $Shape $keys (struct.get $LuaTable $shape (local.get $t)))
                       (local.get $idx))
      (call $tval (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $idx))
                  (struct.get $LuaTable $fvals (local.get $t)) (local.get $idx))))

;; The generic for over `ipairs` / `pairs` without calling the iterator
  ;; (src/codegen/stmt.c, emit_for_gen). $for_gen_mode picks the mode once
  ;; per loop — 1: ipairs's iterator, from an integer (state[i] is the
  ;; ordinary index, as in the iterator); 2: next over a table, from nil;
  ;; 0: anything else, through the call protocol — and the starting
  ;; position.
  (func $for_gen_mode (param $iter anyref) (param $state anyref) (param $k anyref) (result i32 i64)
    (local $f (ref $LuaClosure))
    (if (i32.eqz (ref.test (ref $LuaClosure) (local.get $iter))) (then (return (i32.const 0) (i64.const 0))))
    (local.set $f (ref.cast (ref $LuaClosure) (local.get $iter)))
    (if (ref.eq (local.get $f) (global.get $g_builtin_ipairs_iter))
      (then (if (call $is_int (local.get $k)) (then (return (i32.const 1) (call $as_int (local.get $k)))))))
    (if (ref.eq (local.get $f) (global.get $g_builtin_next))
      (then (if (i32.and (ref.is_null (local.get $k)) (ref.test (ref $LuaTable) (local.get $state)))
        (then (return (i32.const 2) (i64.const 0))))))
    (i32.const 0) (i64.const 0))

  ;; One step of `next` by position instead of by key: $pos >= 0 is the next
  ;; array slot to look at, -(j+1) the next hash position j. Returns the
  ;; position after the entry found, its key and value; a nil key when the
  ;; table is exhausted. The same entries in the same order as next(t, k)
  ;; (whose key lookup finds the position this carries): deleting fields
  ;; keeps positions, and adding one during a traversal is undefined in Lua.
  (func $next_step (param $t (ref $LuaTable)) (param $pos i64) (result i64 anyref anyref)
    (local $i i32) (local $n i32) (local $vals (ref null $TArr)) (local $v anyref)
    (if (i64.ge_s (local.get $pos) (i64.const 0))
      (then
        (local.set $i (i32.wrap_i64 (local.get $pos)))
        (block $array_done (loop $scan
          (br_if $array_done (i32.ge_s (local.get $i) (struct.get $LuaTable $alen (local.get $t))))
          (local.set $v (array.get $TArr (ref.as_non_null (struct.get $LuaTable $arr (local.get $t))) (local.get $i)))
          (if (i32.eqz (ref.is_null (local.get $v)))
            (then (return
              (i64.extend_i32_u (i32.add (local.get $i) (i32.const 1)))
              (ref.i31 (i32.add (local.get $i) (i32.const 1)))
              (call $tval (local.get $v) (struct.get $LuaTable $farr (local.get $t)) (local.get $i)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $scan)))
        (local.set $pos (i64.const -1))))
    (local.set $i (i32.wrap_i64 (i64.sub (i64.const -1) (local.get $pos))))
    (local.set $n (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t))))
    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
    (block $done (loop $scan
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $v (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $i)))
      (if (i32.eqz (ref.is_null (local.get $v)))
        (then (return
          (i64.sub (i64.const -2) (i64.extend_i32_u (local.get $i)))
          (array.get $TArr (struct.get $Shape $keys (struct.get $LuaTable $shape (local.get $t))) (local.get $i))
          (call $tval (local.get $v) (struct.get $LuaTable $fvals (local.get $t)) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $scan)))
    (i64.const 0) (ref.null any) (ref.null any))

  (func $builtin_pairs (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $mm anyref) (local $r (ref $ArgArr))
    (call $need_arg (local.get $args) (i32.const 0))
    ;; __pairs: its first four results.
    (local.set $mm (call $get_metamethod (call $args_at (local.get $args) (i32.const 0))
      (ref.as_non_null (global.get $g_mkey_pairs))))
    (if (i32.eqz (ref.is_null (local.get $mm)))
      (then
        (local.set $r (call $lua_call_any (local.get $mm)
          (array.new_fixed $ArgArr 1 (call $args_at (local.get $args) (i32.const 0))) (call $top_line)))
        (return (array.new_fixed $ArgArr 4
          (call $args_at (local.get $r) (i32.const 0)) (call $args_at (local.get $r) (i32.const 1))
          (call $args_at (local.get $r) (i32.const 2)) (call $args_at (local.get $r) (i32.const 3))))))
    ;; Use the singleton next closure so `pairs(t) == pairs(t)` returns
    ;; the same iterator both times — same identity contract as ipairs.
    (array.new_fixed $ArgArr 3
      (global.get $g_builtin_next)
      (call $args_at (local.get $args) (i32.const 0))
      (ref.null any)))

  ;; ipairs_iter: takes (t, prev_k) where prev_k is an int. Returns next int
  ;; key and t[next_k], or empty when t[next_k] is nil. Like lua_geti, t can
  ;; be any value that indexes (a string's is always nil).
  (func $builtin_ipairs_iter (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t anyref) (local $k i64) (local $v anyref) (local $kref anyref)
    (local.set $t (call $args_at (local.get $args) (i32.const 0)))
    ;; prev_k may be a boxed $LuaInt when it doesn't fit in i31. Use
    ;; $as_int (which handles both reps) and i64 arithmetic so overflow
    ;; wraps the same way reference Lua does — nextvar.lua probes this
    ;; with math.maxinteger.
    (local.set $k (i64.add
      (call $as_int (call $args_at (local.get $args) (i32.const 1)))
      (i64.const 1)))
    (local.set $kref (call $make_int (local.get $k)))
    (local.set $v (call $lua_index_ik (local.get $t) (local.get $k) (call $top_line)))
    (if (ref.is_null (local.get $v))
      (then (return (global.get $g_empty_args))))
    (array.new_fixed $ArgArr 2 (local.get $kref) (local.get $v)))

  (func $builtin_ipairs (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    ;; Return the singleton iter closure so `ipairs{} == ipairs{}` holds
    ;; (reference Lua promises the iterator function is always the same).
    (call $need_arg (local.get $args) (i32.const 0))
    (array.new_fixed $ArgArr 3
      (global.get $g_builtin_ipairs_iter)
      (call $args_at (local.get $args) (i32.const 0))
      (ref.i31 (i32.const 0))))

  (func $builtin_setmetatable (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 1
      (call $set_metatable (call $args_at (local.get $args) (i32.const 0)) (call $args_at (local.get $args) (i32.const 1)))))
  (func $builtin_setmetatable_f (type $LuaFn1) (param $self (ref $LuaClosure))
    (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref) (param $n i32) (result anyref)
    (call $set_metatable (local.get $a0) (local.get $a1)))
  (func $set_metatable (param $arg0 anyref) (param $mt anyref) (result anyref)
    (local $t (ref $LuaTable)) (local $cur (ref null $LuaTable))
    ;; arg #1 must be a table (was an illegal-cast trap for strings/etc.).
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $arg0)))
      (then (call $throw_lit (i32.const 684) (i32.const 14))))   ;; "table expected"
    (local.set $t (ref.cast (ref $LuaTable) (local.get $arg0)))
    ;; arg #2 must be nil or a table.
    (if (i32.and (i32.eqz (ref.is_null (local.get $mt)))
                 (i32.eqz (ref.test (ref $LuaTable) (local.get $mt))))
      (then (call $throw_lit (i32.const 684) (i32.const 14))))   ;; "table expected"
    ;; Protect: if the existing metatable carries __metatable, error.
    (local.set $cur (struct.get $LuaTable $meta (local.get $t)))
    (if (i32.eqz (ref.is_null (local.get $cur)))
      (then
        (if (i32.eqz (ref.is_null
              (call $tab_get_raw (ref.as_non_null (local.get $cur))
                (ref.as_non_null (global.get $g_mkey_metatable)))))
          (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 634) (i32.const 35)) (i32.const 0)))))))
    (if (ref.is_null (local.get $mt))
      (then (struct.set $LuaTable $meta (local.get $t) (ref.null $LuaTable)))
      (else (struct.set $LuaTable $meta (local.get $t)
        (ref.cast (ref $LuaTable) (local.get $mt)))))
    (local.get $t))

  ;; Lazily build (and cache) the shared string metatable {__index = string}.
  (func $get_string_mt (result (ref $LuaTable))
    (local $mt (ref $LuaTable))
    (if (i32.eqz (ref.is_null (global.get $g_string_mt)))
      (then (return (ref.as_non_null (global.get $g_string_mt)))))
    (local.set $mt (call $tab_new))
    ;; Build the metatable with the append-only bootstrap insert (one fresh,
    ;; absent key) rather than $tab_set, so wiring string indexing through here
    ;; doesn't pull the table write path back in for a program that writes no
    ;; tables of its own (keeps the tree-shake write-path DCE win).
    (call $tab_bootstrap_set (local.get $mt)
      (ref.as_non_null (global.get $g_mkey_index))
      (call $tab_get (ref.as_non_null (global.get $g_globals))
        (struct.new $LuaString
          (array.new_data $LuaArr $str_data (i32.const 25) (i32.const 6)) (i32.const 0))))   ;; "string"
    (global.set $g_string_mt (local.get $mt))
    (local.get $mt))

  (func $builtin_getmetatable (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref)
    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable)) (local $guard anyref)
    (call $need_arg (local.get $args) (i32.const 0))
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    ;; Strings share a metatable ({__index = string}); reference exposes it.
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return (array.new_fixed $ArgArr 1 (call $get_string_mt)))))
    ;; Other primitives have no metatable here — return nil (and never trap).
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $t (ref.cast (ref $LuaTable) (local.get $v)))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    ;; If __metatable is set, return it instead of the real metatable.
    (local.set $guard (call $tab_get_raw (ref.as_non_null (local.get $mt))
      (ref.as_non_null (global.get $g_mkey_metatable))))
    (if (i32.eqz (ref.is_null (local.get $guard)))
      (then (return (array.new_fixed $ArgArr 1 (local.get $guard)))))
    (array.new_fixed $ArgArr 1 (ref.as_non_null (local.get $mt))))

  ;; --- require / package (milestone 25) ---
  ;;
  ;; require(name): walk package.loaded → package.preload to find a
  ;; loader closure for "name". On first load, call it, cache the
  ;; (non-nil) result in package.loaded, return it. On hit, return the
  ;; cached value. On miss, raise.
  ;;
  ;; The package table itself is set up in $stdlib_init with empty
  ;; `loaded` and `preload` subtables; codegen prepends each -m module
  ;; as `package.preload[name] = function() ... end`, which runs at the
  ;; start of main before user code calls require().
  (func $builtin_require (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr))
    (result (ref $ArgArr))
    (local $name anyref) (local $pkg (ref $LuaTable))
    (local $loaded (ref $LuaTable)) (local $preload (ref $LuaTable))
    (local $cached anyref) (local $loader anyref) (local $r anyref)
    (local $key_pkg (ref $LuaString)) (local $key_loaded (ref $LuaString))
    (local $key_preload (ref $LuaString))
    (local $err anyref) (local $idx i32)
    (local.set $name (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $name)))
      (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 669) (i32.const 15)) (i32.const 0)))))
    ;; Fetch package, package.loaded, package.preload from _G.
    (local.set $key_pkg (struct.new $LuaString
      (array.new_data $LuaArr $str_data
        (i32.const 0) (i32.const 0)) (i32.const 0)))   ;; placeholder; rebuilt below
    ;; Build the lookup keys via $int_to_bytes is overkill — easier to
    ;; reuse $g_globals's existing dispatch by name. We allocate fresh
    ;; $LuaStrings here (no constant slots for "package"/"loaded"/
    ;; "preload" in the str pool yet).
    (local.set $key_pkg (call $str_from_bytes
      (i32.const 112) (i32.const 97) (i32.const 99) (i32.const 107)
      (i32.const 97) (i32.const 103) (i32.const 101) (i32.const -1)))
    (local.set $key_loaded (call $str_from_bytes
      (i32.const 108) (i32.const 111) (i32.const 97) (i32.const 100)
      (i32.const 101) (i32.const 100) (i32.const -1) (i32.const -1)))
    (local.set $key_preload (call $str_from_bytes
      (i32.const 112) (i32.const 114) (i32.const 101) (i32.const 108)
      (i32.const 111) (i32.const 97) (i32.const 100) (i32.const -1)))
    (local.set $pkg (ref.cast (ref $LuaTable)
      (call $tab_get
        (ref.as_non_null (global.get $g_globals))
        (local.get $key_pkg))))
    (local.set $loaded (ref.cast (ref $LuaTable)
      (call $tab_get (local.get $pkg) (local.get $key_loaded))))
    (local.set $preload (ref.cast (ref $LuaTable)
      (call $tab_get (local.get $pkg) (local.get $key_preload))))
    ;; Cached?
    (local.set $cached (call $tab_get (local.get $loaded)
      (ref.cast (ref $LuaString) (local.get $name))))
    (if (i32.eqz (ref.is_null (local.get $cached)))
      (then (return (array.new_fixed $ArgArr 1 (local.get $cached)))))
    ;; Loader?
    (local.set $loader (call $tab_get (local.get $preload)
      (ref.cast (ref $LuaString) (local.get $name))))
    (if (ref.is_null (local.get $loader))
      (then
        ;; Build "module '<name>' not loaded" and prefix with caller's
        ;; source line so the user sees what's missing and where.
        (local.set $err (call $lua_concat
          (call $lua_concat
            (struct.new $LuaString (array.new_data $LuaArr $str_data
              (i32.const 135) (i32.const 8)) (i32.const 0))
            (local.get $name))
          (struct.new $LuaString (array.new_data $LuaArr $str_data
            (i32.const 143) (i32.const 12)) (i32.const 0))))
        (local.set $idx (i32.sub (global.get $call_depth) (i32.const 1)))
        (if (i32.ge_s (local.get $idx) (i32.const 0))
          (then (local.set $err (call $prefix_error_msg
            (ref.as_non_null (global.get $g_src_name))
            (array.get $LineArr
              (ref.as_non_null (global.get $call_lines))
              (local.get $idx))
            (ref.cast (ref $LuaString) (local.get $err))))))
        (throw $LuaError (local.get $err))))
    ;; Call loader(name).
    (local.set $r (call $args_first
      (call $lua_call_any (local.get $loader)
        (array.new_fixed $ArgArr 1 (local.get $name))
        (i32.const 0))))
    ;; nil result becomes true (per Lua spec).
    (if (ref.is_null (local.get $r))
      (then (local.set $r (global.get $g_true))))
    (call $tab_set (local.get $loaded)
      (ref.cast (ref $LuaString) (local.get $name)) (local.get $r))
    (array.new_fixed $ArgArr 1 (local.get $r)))

  ;; collectgarbage(opt[, arg]): lua2wasm has no managed GC of its own
  ;; (the host's collector owns every value), so this is a stub. It
  ;; dispatches on opt's length+first-byte to give back the shape Lua
  ;; programs expect: "count" → 0.0, "isrunning" → true, everything
  ;; else (including nil/"collect"/"stop"/"step"/"setpause"/"generational")
  ;; → integer 0. Enough to satisfy the boilerplate the upstream test
  ;; suite sprinkles around its real GC tests.
  (func $builtin_collectgarbage (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $opt anyref) (local $b (ref $LuaArr)) (local $blen i32) (local $b0 i32)
    (local.set $opt (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $opt)))
      (then (return (array.new_fixed $ArgArr 1 (ref.i31 (i32.const 0))))))
    (local.set $b
      (call $str_bytes (ref.cast (ref $LuaString) (local.get $opt))))
    (local.set $blen (array.len (local.get $b)))
    (if (i32.gt_s (local.get $blen) (i32.const 0))
      (then (local.set $b0 (array.get_u $LuaArr (local.get $b) (i32.const 0)))))
    ;; "count" → 0.0
    (if (i32.and (i32.eq (local.get $blen) (i32.const 5))
                 (i32.eq (local.get $b0) (i32.const 99)))   ;; 'c'
      (then (return (array.new_fixed $ArgArr 1
              (struct.new $LuaFloat (f64.const 0))))))
    ;; "isrunning" → true
    (if (i32.and (i32.eq (local.get $blen) (i32.const 9))
                 (i32.eq (local.get $b0) (i32.const 105)))  ;; 'i'
      (then (return (array.new_fixed $ArgArr 1 (global.get $g_true)))))
    ;; "generational" / "incremental" → previous mode then switch.
    ;; (No real Lua GC behind this; we just track the user's last
    ;; requested mode in $g_gc_mode so the round-trip in
    ;; assert(collectgarbage("generational") == "incremental") works.)
    (if (i32.and (i32.eq (local.get $blen) (i32.const 12))
                 (i32.eq (local.get $b0) (i32.const 103)))   ;; 'g'enerational
      (then
        (local.set $b0 (global.get $g_gc_mode))
        (global.set $g_gc_mode (i32.const 1))
        (return (array.new_fixed $ArgArr 1
          (call $gc_mode_name (local.get $b0))))))
    (if (i32.and (i32.eq (local.get $blen) (i32.const 11))
                 (i32.eq (local.get $b0) (i32.const 105)))   ;; 'i'ncremental
      (then
        (local.set $b0 (global.get $g_gc_mode))
        (global.set $g_gc_mode (i32.const 0))
        (return (array.new_fixed $ArgArr 1
          (call $gc_mode_name (local.get $b0))))))
    (array.new_fixed $ArgArr 1 (ref.i31 (i32.const 0))))

  ;; Renders a $g_gc_mode value (0 = incremental, 1 = generational) into
  ;; its canonical $LuaString form.
  (func $gc_mode_name (param $mode i32) (result (ref $LuaString))
    (if (result (ref $LuaString)) (local.get $mode)
      (then (struct.new $LuaString
        (array.new_fixed $LuaArr 12
          (i32.const 103) (i32.const 101) (i32.const 110)     ;; g,e,n
          (i32.const 101) (i32.const 114) (i32.const 97)      ;; e,r,a
          (i32.const 116) (i32.const 105) (i32.const 111)     ;; t,i,o
          (i32.const 110) (i32.const 97) (i32.const 108)) (i32.const 0)))   ;; n,a,l
      (else (struct.new $LuaString
        (array.new_fixed $LuaArr 11
          (i32.const 105) (i32.const 110) (i32.const 99)      ;; i,n,c
          (i32.const 114) (i32.const 101) (i32.const 109)     ;; r,e,m
          (i32.const 101) (i32.const 110) (i32.const 116)     ;; e,n,t
          (i32.const 97)  (i32.const 108)) (i32.const 0)))))                ;; a,l

  ;; load(chunk[, name[, mode[, env]]]): no runtime compiler available
  ;; in lua2wasm — code is AOT-compiled to wasm. Return (nil, errmsg) to
  ;; match the on-syntax-error contract; callers in the form
  ;;     local f, err = load(s); if not f then …
  ;; see the error string and take their failure branch.
  (func $builtin_load (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    ;; $str_from_bytes caps at 8 bytes, so we can only return a short
    ;; sentinel message — but `type(err) == "string"` is what callers
    ;; actually probe, so this is enough.
    (array.new_fixed $ArgArr 2
      (ref.null any)
      (call $str_from_bytes
        (i32.const 110) (i32.const 111) (i32.const 32)                    ;; "no "
        (i32.const 108) (i32.const 111) (i32.const 97) (i32.const 100)    ;; "load"
        (i32.const -1))))

  ;; Build a $LuaString from up to 8 ASCII byte codes; the first -1
  ;; (i32.const -1) terminates the sequence early. Used by builtins
  ;; that need a short literal name without consuming a strpool slot.
  (func $str_from_bytes
    (param $b0 i32) (param $b1 i32) (param $b2 i32) (param $b3 i32)
    (param $b4 i32) (param $b5 i32) (param $b6 i32) (param $b7 i32)
    (result (ref $LuaString))
    (local $arr (ref $LuaArr)) (local $n i32)
    ;; Count active bytes (up to first -1).
    (local.set $n (i32.const 8))
    (if (i32.lt_s (local.get $b7) (i32.const 0)) (then (local.set $n (i32.const 7))))
    (if (i32.and (i32.eq (local.get $n) (i32.const 7))
                 (i32.lt_s (local.get $b6) (i32.const 0)))
      (then (local.set $n (i32.const 6))))
    (if (i32.and (i32.eq (local.get $n) (i32.const 6))
                 (i32.lt_s (local.get $b5) (i32.const 0)))
      (then (local.set $n (i32.const 5))))
    (if (i32.and (i32.eq (local.get $n) (i32.const 5))
                 (i32.lt_s (local.get $b4) (i32.const 0)))
      (then (local.set $n (i32.const 4))))
    (if (i32.and (i32.eq (local.get $n) (i32.const 4))
                 (i32.lt_s (local.get $b3) (i32.const 0)))
      (then (local.set $n (i32.const 3))))
    (if (i32.and (i32.eq (local.get $n) (i32.const 3))
                 (i32.lt_s (local.get $b2) (i32.const 0)))
      (then (local.set $n (i32.const 2))))
    (if (i32.and (i32.eq (local.get $n) (i32.const 2))
                 (i32.lt_s (local.get $b1) (i32.const 0)))
      (then (local.set $n (i32.const 1))))
    (local.set $arr (array.new $LuaArr (i32.const 0) (local.get $n)))
    (if (i32.gt_s (local.get $n) (i32.const 0))
      (then (array.set $LuaArr (local.get $arr) (i32.const 0) (local.get $b0))))
    (if (i32.gt_s (local.get $n) (i32.const 1))
      (then (array.set $LuaArr (local.get $arr) (i32.const 1) (local.get $b1))))
    (if (i32.gt_s (local.get $n) (i32.const 2))
      (then (array.set $LuaArr (local.get $arr) (i32.const 2) (local.get $b2))))
    (if (i32.gt_s (local.get $n) (i32.const 3))
      (then (array.set $LuaArr (local.get $arr) (i32.const 3) (local.get $b3))))
    (if (i32.gt_s (local.get $n) (i32.const 4))
      (then (array.set $LuaArr (local.get $arr) (i32.const 4) (local.get $b4))))
    (if (i32.gt_s (local.get $n) (i32.const 5))
      (then (array.set $LuaArr (local.get $arr) (i32.const 5) (local.get $b5))))
    (if (i32.gt_s (local.get $n) (i32.const 6))
      (then (array.set $LuaArr (local.get $arr) (i32.const 6) (local.get $b6))))
    (if (i32.gt_s (local.get $n) (i32.const 7))
      (then (array.set $LuaArr (local.get $arr) (i32.const 7) (local.get $b7))))
    (struct.new $LuaString (local.get $arr) (i32.const 0)))
