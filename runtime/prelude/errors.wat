;; Errors: the $LuaError tag, raising errors with a position prefix, and
;; argument checks shared by the libraries.

  (tag $LuaError (export "LuaError") (param anyref))

  ;; The message handler of the innermost active xpcall (null under a pcall
  ;; and at top level), how many calls of it are in progress, and how deep
  ;; those may nest — a handler raising inside a handler — before the error
  ;; becomes "error in error handling".
  (global $msgh (mut anyref) (ref.null any))
  (global $msgh_nest (mut i32) (i32.const 0))
  (global $msgh_max_nest i32 (i32.const 20))

  ;; The value a newly raised error carries, built the way reference Lua's
  ;; luaG_errormsg builds it: the innermost xpcall's message handler runs
  ;; here, where the error is raised and before anything unwinds (so a
  ;; <close> variable's __close receives the handler's result), then a nil
  ;; error object becomes "<no error object>". Every raise is
  ;; `(throw $LuaError (call $raised v))`; only rethrowing an error already
  ;; raised (the close machinery) throws the value bare.
  ;;
  ;; The handler stays installed while it runs, so an error it raises is
  ;; handled in turn, and that result is what propagates; one that keeps
  ;; raising ends in "error in error handling". The outermost handler call
  ;; runs with headroom past the stack budget, so a handler still gets to run
  ;; after a stack overflow.
  (func $raised (param $e anyref) (result anyref)
    (local $h anyref) (local $outer i32) (local $reraised i32)
    (local.set $h (global.get $msgh))
    (if (i32.eqz (ref.is_null (local.get $h)))
      (then
        (if (i32.ge_u (global.get $msgh_nest) (global.get $msgh_max_nest))
          (then (return (struct.new $LuaString
            (array.new_data $LuaArr $str_data (i32.const 1208) (i32.const 23)) (i32.const 0)))))
        (local.set $outer (i32.eqz (global.get $msgh_nest)))
        (global.set $msgh_nest (i32.add (global.get $msgh_nest) (i32.const 1)))
        (if (local.get $outer)
          (then (global.set $stack_cost (i32.sub (global.get $stack_cost) (global.get $stack_headroom)))))
        (block $handled
          (block $hcatch (result anyref)
            (local.set $e (call $args_first
              (try_table (result (ref $ArgArr)) (catch $LuaError $hcatch)
                (call $lua_call_any (local.get $h)
                  (array.new_fixed $ArgArr 1 (local.get $e)) (call $top_line)))))
            (br $handled))
          ;; The handler raised: that error, already handled, replaces this one.
          (local.set $e)
          (local.set $reraised (i32.const 1)))
        (global.set $msgh_nest (i32.sub (global.get $msgh_nest) (i32.const 1)))
        (if (local.get $outer)
          (then (global.set $stack_cost (i32.add (global.get $stack_cost) (global.get $stack_headroom)))))
        (if (local.get $reraised)
          (then (throw $LuaError (local.get $e))))))   ;; rethrow: raised by the handler
    (if (result anyref) (ref.is_null (local.get $e))
      (then (struct.new $LuaString
              (array.new_data $LuaArr $str_data (i32.const 768) (i32.const 17)) (i32.const 0)))
      (else (local.get $e))))

  ;; Build "<src>:<line>: <msg>" as a new $LuaString.
  (func $prefix_error_msg
    (param $src (ref $LuaString)) (param $line i32) (param $msg (ref $LuaString))
    (result (ref $LuaString))
    (local $src_b (ref $LuaArr)) (local $line_b (ref $LuaArr))
    (local $msg_b (ref $LuaArr)) (local $out (ref $LuaArr))
    (local $off i32) (local $total i32)
    (local.set $src_b (call $str_bytes (local.get $src)))
    (local.set $line_b (call $int_to_bytes (i64.extend_i32_s (local.get $line))))
    (local.set $msg_b (call $str_bytes (local.get $msg)))
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
  ;; The source line of the innermost call: where an error raised inside a
  ;; builtin is reported.
  (func $top_line (result i32)
    (if (result i32) (i32.gt_s (global.get $call_depth) (i32.const 0))
      (then (array.get $LineArr (ref.as_non_null (global.get $call_lines))
                                (i32.sub (global.get $call_depth) (i32.const 1))))
      (else (i32.const 0))))
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
    (throw $LuaError (call $raised (local.get $err))))

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
    (throw $LuaError (call $raised (call $prefix_error_msg
      (ref.as_non_null (global.get $g_src_name))
      (local.get $line)
      (struct.new $LuaString
        (array.new_data $LuaArr $str_data (local.get $off) (local.get $len)) (i32.const 0))))))

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
