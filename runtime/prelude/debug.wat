;; The debug library subset: traceback, get/setmetatable, gethook.

  ;; Returns a "stack traceback:\n  <src>:<line>:\n  <src>:<line>:..."
  ;; string. Optional first arg = prefix message, second arg = level
  ;; (defaults to 1 = caller of traceback). debug.traceback walks the
  ;; same $call_lines stack error() uses.
  (func $builtin_debug_traceback (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $msg anyref) (local $level i32) (local $b (ref $Builder))
    (local $i i32) (local $line i32) (local $line_b (ref $LuaArr))
    (local $src_b (ref $LuaArr))
    (local.set $msg (call $args_at (local.get $args) (i32.const 0)))
    ;; If msg is present but neither a string nor nil, return it
    ;; unchanged (per Lua spec).
    (if (i32.and (i32.eqz (ref.is_null (local.get $msg)))
                 (i32.eqz (ref.test (ref $LuaString) (local.get $msg))))
      (then (return (array.new_fixed $ArgArr 1 (local.get $msg)))))
    (local.set $level (i32.const 1))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (local.set $level (i32.wrap_i64
              (call $as_int
                (call $args_at (local.get $args) (i32.const 1)))))))
    (local.set $b (call $builder_new))
    ;; Optional prefix message + newline.
    (if (ref.test (ref $LuaString) (local.get $msg))
      (then
        (local.set $src_b (struct.get $LuaString $bytes
          (ref.cast (ref $LuaString) (local.get $msg))))
        (call $builder_append (local.get $b) (local.get $src_b)
                              (i32.const 0) (array.len (local.get $src_b)))
        (call $builder_append_byte (local.get $b) (i32.const 10))))
    ;; "stack traceback:"
    (call $builder_append_byte (local.get $b) (i32.const 115))     ;; 's'
    (call $builder_append_byte (local.get $b) (i32.const 116))     ;; 't'
    (call $builder_append_byte (local.get $b) (i32.const 97))      ;; 'a'
    (call $builder_append_byte (local.get $b) (i32.const 99))      ;; 'c'
    (call $builder_append_byte (local.get $b) (i32.const 107))     ;; 'k'
    (call $builder_append_byte (local.get $b) (i32.const 32))
    (call $builder_append_byte (local.get $b) (i32.const 116))     ;; 't'
    (call $builder_append_byte (local.get $b) (i32.const 114))     ;; 'r'
    (call $builder_append_byte (local.get $b) (i32.const 97))
    (call $builder_append_byte (local.get $b) (i32.const 99))
    (call $builder_append_byte (local.get $b) (i32.const 101))     ;; 'e'
    (call $builder_append_byte (local.get $b) (i32.const 98))      ;; 'b'
    (call $builder_append_byte (local.get $b) (i32.const 97))
    (call $builder_append_byte (local.get $b) (i32.const 99))
    (call $builder_append_byte (local.get $b) (i32.const 107))
    (call $builder_append_byte (local.get $b) (i32.const 58))      ;; ':'
    ;; Walk frames from depth-level down to 0.
    (local.set $src_b (struct.get $LuaString $bytes
      (ref.as_non_null (global.get $g_src_name))))
    (local.set $i (i32.sub (global.get $call_depth) (local.get $level)))
    (block $tb_done (loop $tb_lp
      (br_if $tb_done (i32.lt_s (local.get $i) (i32.const 0)))
      (call $builder_append_byte (local.get $b) (i32.const 10))    ;; '\n'
      (call $builder_append_byte (local.get $b) (i32.const 9))     ;; '\t'
      (call $builder_append (local.get $b) (local.get $src_b)
                            (i32.const 0) (array.len (local.get $src_b)))
      (call $builder_append_byte (local.get $b) (i32.const 58))    ;; ':'
      (local.set $line (array.get $LineArr
        (ref.as_non_null (global.get $call_lines)) (local.get $i)))
      (local.set $line_b (call $int_to_bytes
        (i64.extend_i32_s (local.get $line))))
      (call $builder_append (local.get $b) (local.get $line_b)
                            (i32.const 0) (array.len (local.get $line_b)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $tb_lp)))
    (array.new_fixed $ArgArr 1 (call $builder_finish (local.get $b))))

  ;; debug.getmetatable(v) — like base but ignores __metatable.
  ;; Currently only $LuaTable values carry metatables; for others
  ;; returns nil (no per-type metatable infrastructure yet).
  (func $builtin_debug_getmetatable (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref) (local $mt (ref null $LuaTable))
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $mt (struct.get $LuaTable $meta
      (ref.cast (ref $LuaTable) (local.get $v))))
    (if (ref.is_null (local.get $mt))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (array.new_fixed $ArgArr 1 (ref.as_non_null (local.get $mt))))

  ;; debug.setmetatable(v, t) — like base but ignores __metatable
  ;; protection. Only applies to tables for now (no per-type meta).
  (func $builtin_debug_setmetatable (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $mt anyref)
    (local.set $t (ref.cast (ref $LuaTable)
      (call $args_at (local.get $args) (i32.const 0))))
    (local.set $mt (call $args_at (local.get $args) (i32.const 1)))
    (if (ref.is_null (local.get $mt))
      (then (struct.set $LuaTable $meta (local.get $t) (ref.null $LuaTable)))
      (else (struct.set $LuaTable $meta (local.get $t)
        (ref.cast (ref $LuaTable) (local.get $mt)))))
    (array.new_fixed $ArgArr 1 (local.get $t)))

  ;; debug.gethook(): no debug hooks are installed in lua2wasm, so we
  ;; return (nil, "", 0) — the same shape stock Lua returns when no
  ;; hook is set. Some tests probe this to decide whether to run hook-
  ;; dependent paths; with nil they take the no-hook branch.
  (func $builtin_debug_gethook (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (array.new_fixed $ArgArr 3
      (ref.null any)
      (ref.as_non_null (global.get $g_empty_str))
      (ref.i31 (i32.const 0))))
