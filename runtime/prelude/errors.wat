;; Errors: the $LuaError tag, raising errors with a position prefix, and
;; argument checks shared by the libraries.

  (tag $LuaError (export "LuaError") (param anyref))

  ;; Build "<src>:<line>: <msg>" as a new $LuaString.
  (func $prefix_error_msg
    (param $src (ref $LuaString)) (param $line i32) (param $msg (ref $LuaString))
    (result (ref $LuaString))
    (local $src_b (ref $LuaArr)) (local $line_b (ref $LuaArr))
    (local $msg_b (ref $LuaArr)) (local $out (ref $LuaArr))
    (local $off i32) (local $total i32)
    (local.set $src_b (struct.get $LuaString $bytes (local.get $src)))
    (local.set $line_b (call $int_to_bytes (i64.extend_i32_s (local.get $line))))
    (local.set $msg_b (struct.get $LuaString $bytes (local.get $msg)))
    (local.set $total
      (i32.add (array.len (local.get $src_b))
      (i32.add (i32.const 1)
      (i32.add (array.len (local.get $line_b))
      (i32.add (i32.const 2)
               (array.len (local.get $msg_b)))))))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $total)))
    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)
      (local.get $src_b) (i32.const 0) (array.len (local.get $src_b)))
    (local.set $off (array.len (local.get $src_b)))
    (array.set $LuaArr (local.get $out) (local.get $off) (i32.const 58))  ;; ':'
    (local.set $off (i32.add (local.get $off) (i32.const 1)))
    (array.copy $LuaArr $LuaArr (local.get $out) (local.get $off)
      (local.get $line_b) (i32.const 0) (array.len (local.get $line_b)))
    (local.set $off (i32.add (local.get $off) (array.len (local.get $line_b))))
    (array.set $LuaArr (local.get $out) (local.get $off) (i32.const 58))  ;; ':'
    (array.set $LuaArr (local.get $out)
      (i32.add (local.get $off) (i32.const 1)) (i32.const 32))             ;; ' '
    (local.set $off (i32.add (local.get $off) (i32.const 2)))
    (array.copy $LuaArr $LuaArr (local.get $out) (local.get $off)
      (local.get $msg_b) (i32.const 0) (array.len (local.get $msg_b)))
    (struct.new $LuaString (local.get $out) (i32.const 0)))

  ;; Throw a $LuaError carrying "<src>:<line>: <msg>", where <line> is
  ;; the topmost active call frame's source position — i.e. the
  ;; builtin's caller in user code. The frame stack is left intact on
  ;; throw paths (we skip pop), so this works wherever an internal
  ;; error needs to surface to user code.
  (func $throw_at_top (param $msg (ref $LuaString))
    (local $idx i32) (local $err (ref $LuaString))
    (local.set $err (local.get $msg))
    (local.set $idx (i32.sub (global.get $call_depth) (i32.const 1)))
    (if (i32.ge_s (local.get $idx) (i32.const 0))
      (then (local.set $err (call $prefix_error_msg
        (ref.as_non_null (global.get $g_src_name))
        (array.get $LineArr
          (ref.as_non_null (global.get $call_lines))
          (local.get $idx))
        (local.get $msg)))))
    (throw $LuaError (local.get $err)))

  ;; Same, but the message is a string-pool literal addressed by
  ;; (offset, length). Saves the boilerplate at the ~dozen sites that
  ;; just want to throw a fixed error and let prefix_error_msg attach
  ;; the file:line.
  (func $throw_lit (param $off i32) (param $len i32)
    (call $throw_at_top
      (struct.new $LuaString
        (array.new_data $LuaArr $str_data (local.get $off) (local.get $len)) (i32.const 0))))

  ;; Positioned variant of $throw_lit: prefix the literal with "<src>:<line>: "
  ;; using the error's own source line rather than the topmost call frame's.
  (func $throw_lit_at (param $off i32) (param $len i32) (param $line i32)
    (throw $LuaError (call $prefix_error_msg
      (ref.as_non_null (global.get $g_src_name))
      (local.get $line)
      (struct.new $LuaString
        (array.new_data $LuaArr $str_data (local.get $off) (local.get $len)) (i32.const 0)))))

  ;; Argument validators: turn the bare ref.cast a builtin would otherwise do on
  ;; a user argument into a catchable Lua error, so pcall recovers instead of
  ;; the whole module aborting on an illegal-cast trap.
  ;;
  ;; $arg_table requires a table. $arg_string mirrors luaL_checkstring: a string
  ;; passes through, a number is coerced to its string form, anything else
  ;; raises a catchable "string expected".
  (func $arg_table (param $v anyref) (result (ref $LuaTable))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v)))
      (then (call $throw_lit (i32.const 684) (i32.const 14)) (unreachable)))   ;; "table expected"
    (ref.cast (ref $LuaTable) (local.get $v)))

  (func $arg_string (param $v anyref) (result (ref $LuaString))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return (ref.cast (ref $LuaString) (local.get $v)))))
    (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
      (then (return (call $lua_tostring (local.get $v)))))
    (call $throw_lit (i32.const 669) (i32.const 15))   ;; "string expected"
    (unreachable))

  ;; luaL_checkany: require an argument to be present at index $n (an explicit
  ;; nil counts). Raises "value expected" when the call passed fewer args, so
  ;; builtins like tostring()/getmetatable()/math.max() error instead of
  ;; treating a missing argument as nil.
  (func $need_arg (param $args (ref $ArgArr)) (param $n i32)
    (if (i32.le_u (array.len (local.get $args)) (local.get $n))
      (then (call $throw_lit (i32.const 620) (i32.const 14)))))   ;; "value expected"
