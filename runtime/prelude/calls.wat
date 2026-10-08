;; Calls: the call-frame stack and its budget, calling closures and other
;; values (fast single-result entries, __call), argument arrays and
;; multiple results.

  ;; Call-frame line stack. Doubled on overflow by $push_call_frame.
  ;; $call_depth is the count of active frames; index 0..depth-1 is live.
  (global $call_lines (mut (ref null $LineArr)) (ref.null $LineArr))
  (global $g_fmark (ref $FMark) (struct.new $FMark))
  (global $call_depth (mut i32) (i32.const 0))
  ;; Stack budget: the sum of the active frames' closure weights (estimated
  ;; wasm frame bytes, see codegen fn_weight). $push_call_frame raises a
  ;; catchable "stack overflow" when it would pass $stack_budget, well before
  ;; the engine's own (uncatchable) limit — a count of frames alone can't do
  ;; that, since frame sizes differ by an order of magnitude across functions.
  (global $stack_cost (mut i32) (i32.const 0))
  (global $stack_budget i32 (i32.const 819200))
  (global $call_weights (mut (ref null $LineArr)) (ref.null $LineArr))

  ;; --- call frames ---
  ;;
  ;; $push_call_frame writes $line at index $call_depth and increments
  ;; depth. Grows the backing array (initial cap 256, doubling) when
  ;; depth would overflow. The pop counterpart is just a decrement —
  ;; on the error path it's outer-pcall's responsibility to restore
  ;; depth to its pre-try value.
  (func $push_call_frame (param $line i32) (param $weight i32)
    ;; Depth guard: raise a *catchable* "stack overflow" before deep non-tail
    ;; recursion exhausts the host's WASM call stack (which would be an
    ;; uncatchable trap). The cap sits below the trap point with headroom to
    ;; build+throw the error; pcall/xpcall save and restore $call_depth, so the
    ;; catch unwinds cleanly. Tail calls use $replace_top_call_frame (no push),
    ;; so proper-TCO loops are unaffected. Very heavy frames can still trap
    ;; below this cap — the host stack size is a runtime-config concern.
    (global.set $stack_cost (i32.add (global.get $stack_cost) (local.get $weight)))
    (if (i32.gt_s (global.get $stack_cost) (global.get $stack_budget))
      (then (call $throw_lit (i32.const 971) (i32.const 14))))   ;; "stack overflow"
    (if (i32.ge_s (global.get $call_depth) (array.len (ref.as_non_null (global.get $call_lines))))
      (then (call $grow_call_frames)))
    (array.set $LineArr (ref.as_non_null (global.get $call_lines))
      (global.get $call_depth) (local.get $line))
    (array.set $LineArr (ref.as_non_null (global.get $call_weights))
      (global.get $call_depth) (local.get $weight))
    (global.set $call_depth
      (i32.add (global.get $call_depth) (i32.const 1))))
  ;; Double the capacity of the call-frame line/weight stacks.
  (func $grow_call_frames
    (local $cap i32) (local $new (ref $LineArr))
    (local.set $cap (array.len (ref.as_non_null (global.get $call_lines))))
    (local.set $new (array.new $LineArr (i32.const 0) (i32.shl (local.get $cap) (i32.const 1))))
    (array.copy $LineArr $LineArr (local.get $new) (i32.const 0)
      (ref.as_non_null (global.get $call_lines)) (i32.const 0) (local.get $cap))
    (global.set $call_lines (local.get $new))
    (local.set $new (array.new $LineArr (i32.const 0) (i32.shl (local.get $cap) (i32.const 1))))
    (array.copy $LineArr $LineArr (local.get $new) (i32.const 0)
      (ref.as_non_null (global.get $call_weights)) (i32.const 0) (local.get $cap))
    (global.set $call_weights (local.get $new)))


  (func $pop_call_frame
    (if (i32.gt_s (global.get $call_depth) (i32.const 0))
      (then
        (global.set $call_depth (i32.sub (global.get $call_depth) (i32.const 1)))
        (global.set $stack_cost (i32.sub (global.get $stack_cost)
          (array.get $LineArr (ref.as_non_null (global.get $call_weights)) (global.get $call_depth)))))))

  ;; Tail calls reuse the caller's WASM frame, so semantically the top
  ;; entry is *replaced*, not pushed. Codegen emits this immediately
  ;; before return_call_ref.
  ;; A tail call replaces the top frame: its line and its weight (the wasm
  ;; frame is replaced too, so the budget swaps rather than grows).
  (func $replace_top_call_frame (param $line i32) (param $weight i32)
    (local $idx i32) (local $weights (ref $LineArr))
    (local.set $idx (i32.sub (global.get $call_depth) (i32.const 1)))
    (if (i32.ge_s (local.get $idx) (i32.const 0))
      (then
        (array.set $LineArr (ref.as_non_null (global.get $call_lines)) (local.get $idx) (local.get $line))
        (local.set $weights (ref.as_non_null (global.get $call_weights)))
        (global.set $stack_cost (i32.add (i32.sub (global.get $stack_cost)
          (array.get $LineArr (local.get $weights) (local.get $idx))) (local.get $weight)))
        (array.set $LineArr (local.get $weights) (local.get $idx) (local.get $weight))
        (if (i32.gt_s (global.get $stack_cost) (global.get $stack_budget))
          (then (call $throw_lit (i32.const 971) (i32.const 14)))))))   ;; "stack overflow"

  ;; --- closure dispatch + multi-value helpers ---
  (func $lua_call (param $closure (ref $LuaClosure)) (param $args (ref $ArgArr))
                  (result (ref $ArgArr))
    (call_ref $LuaFn
      (local.get $closure)
      (local.get $args)
      (struct.get $LuaClosure $code (local.get $closure))))

  ;; The first $n of a0..a3 as an argument array.
  (func $pack_args4 (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref)
                    (param $n i32) (result (ref $ArgArr))
    (block $b0 (block $b1 (block $b2 (block $b3 (block $b4
      (br_table $b0 $b1 $b2 $b3 $b4 (local.get $n)))
      (return (array.new_fixed $ArgArr 4 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3))))
      (return (array.new_fixed $ArgArr 3 (local.get $a0) (local.get $a1) (local.get $a2))))
      (return (array.new_fixed $ArgArr 2 (local.get $a0) (local.get $a1))))
      (return (array.new_fixed $ArgArr 1 (local.get $a0))))
    (global.get $g_empty_args))

  ;; The `...` of a fast-entry call: a{from}..a{n-1}.
  (func $varargs_tail4 (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref)
                       (param $from i32) (param $n i32) (result (ref $ArgArr))
    (local $all (ref $ArgArr))
    (if (i32.ge_s (local.get $from) (local.get $n)) (then (return (global.get $g_empty_args))))
    (if (i32.eqz (local.get $from))
      (then (return (call $pack_args4 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3)
                                      (local.get $n)))))
    (local.set $all (call $pack_args4 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3)
                                      (local.get $n)))
    (call $args_slice (local.get $all) (local.get $from)))

  ;; $LuaFn1 for closures without a body of their own (builtins, functions
  ;; with more than four parameters): pack the arguments, call $code, keep
  ;; the first result.
  (func $fast_adapter (type $LuaFn1) (param $c (ref $LuaClosure))
                      (param $a0 anyref) (param $a1 anyref) (param $a2 anyref) (param $a3 anyref)
                      (param $n i32) (result anyref)
    (call $args_first (call_ref $LuaFn (local.get $c)
      (call $pack_args4 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $n))
      (struct.get $LuaClosure $code (local.get $c)))))
  (elem declare func $fast_adapter)

  ;; Call `f` with $n (<= 4) arguments for one result: the $lua_call_any of
  ;; single-value call sites. A closure goes through its fast entry with the
  ;; same frame bookkeeping; anything else (__call, a non-callable) takes the
  ;; generic path.
  (func $lua_call1 (param $f anyref) (param $a0 anyref) (param $a1 anyref) (param $a2 anyref)
                   (param $a3 anyref) (param $n i32) (param $line i32) (result anyref)
    (local $c (ref $LuaClosure)) (local $r anyref)
    (if (ref.test (ref $LuaClosure) (local.get $f))
      (then
        (local.set $c (ref.cast (ref $LuaClosure) (local.get $f)))
        (call $push_call_frame (local.get $line) (struct.get $LuaClosure $weight (local.get $c)))
        (local.set $r (call_ref $LuaFn1 (local.get $c)
          (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $n)
          (struct.get $LuaClosure $fast (local.get $c))))
        (call $pop_call_frame)
        (return (local.get $r))))
    (return_call $lua_call1_slow (local.get $f)
      (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $n) (local.get $line)))
  ;; A non-closure callee: __call, or the "attempt to call" error.
  (func $lua_call1_slow (param $f anyref) (param $a0 anyref) (param $a1 anyref) (param $a2 anyref)
                        (param $a3 anyref) (param $n i32) (param $line i32) (result anyref)
    (call $args_first (call $lua_call_any (local.get $f)
      (call $pack_args4 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $n))
      (local.get $line))))

  ;; Call any Lua value as a function, walking __call metamethods. Throws
  ;; a Lua-shaped "attempt to call a non-function value" $LuaError if
  ;; the chain bottoms out on a non-callable. A small iteration cap
  ;; keeps a cyclic __call from looping forever.
  ;;
  ;; $line is the source line of the call site, pushed onto the frame
  ;; stack so error() / debug.traceback can report it. Popped on normal
  ;; return; left elevated on the throw paths so the enclosing pcall
  ;; can restore $call_depth.
  ;; A metamethod or library callback called for one result, with $n (<= 3)
  ;; arguments and no call frame of its own (like $lua_call): a closure goes
  ;; through its fast entry; anything else — a callable table — through
  ;; $lua_call_any (which walks __call and raises for a non-callable).
  (func $call_mm1 (param $f anyref) (param $a0 anyref) (param $a1 anyref) (param $a2 anyref)
                  (param $n i32) (result anyref)
    (local $c (ref $LuaClosure))
    (if (ref.test (ref $LuaClosure) (local.get $f))
      (then
        (local.set $c (ref.cast (ref $LuaClosure) (local.get $f)))
        (return (call_ref $LuaFn1 (local.get $c)
          (local.get $a0) (local.get $a1) (local.get $a2) (ref.null any) (local.get $n)
          (struct.get $LuaClosure $fast (local.get $c))))))
    (call $args_first (call $lua_call_any (local.get $f)
      (call $pack_args4 (local.get $a0) (local.get $a1) (local.get $a2) (ref.null any) (local.get $n))
      (i32.const 0))))

  (func $lua_call_any (param $v anyref) (param $args (ref $ArgArr))
                      (param $line i32) (result (ref $ArgArr))
    (local $mm anyref) (local $i i32) (local $r (ref $ArgArr))
    (local.set $i (i32.const 0))
    (loop $resolve
      (if (ref.test (ref $LuaClosure) (local.get $v))
        (then
          (call $push_call_frame (local.get $line)
            (struct.get $LuaClosure $weight (ref.cast (ref $LuaClosure) (local.get $v))))
          (local.set $r (call $lua_call
                          (ref.cast (ref $LuaClosure) (local.get $v))
                          (local.get $args)))
          (call $pop_call_frame)
          (return (local.get $r))))
      (local.set $mm (call $get_metamethod (local.get $v)
                       (ref.as_non_null (global.get $g_mkey_call))))
      (if (ref.is_null (local.get $mm))
        (then (throw $LuaError
          (call $prefix_error_msg
            (ref.as_non_null (global.get $g_src_name))
            (local.get $line)
            (struct.new $LuaString
              (array.new_data $LuaArr $str_data (i32.const 93) (i32.const 36)) (i32.const 0))))))
      ;; Prepend the original callee so __call sees `self`.
      (local.set $args (call $merge_args
        (array.new_fixed $ArgArr 1 (local.get $v))
        (local.get $args)))
      (local.set $v (local.get $mm))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $resolve (i32.lt_s (local.get $i) (i32.const 200))))
    (throw $LuaError
      (call $prefix_error_msg
        (ref.as_non_null (global.get $g_src_name))
        (local.get $line)
        (struct.new $LuaString
          (array.new_data $LuaArr $str_data (i32.const 93) (i32.const 36)) (i32.const 0)))))

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
  ;; Uses the unboxed-int-key setter ($tab_set_ik) so the integer key never
  ;; gets boxed as an i31 first; it still routes through the same array/hash
  ;; placement logic as $tab_set, so nil holes and hash spill behave
  ;; identically. (A bulk array.copy is not safe here: the spread args may
  ;; contain nils, which must not become the array part's last slot.)
  (func $tab_append_args (param $t (ref $LuaTable)) (param $pos i32) (param $args (ref $ArgArr))
    (local $i i32) (local $n i32)
    (local.set $n (array.len (local.get $args)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (call $tab_set_ik (local.get $t)
        (i64.extend_i32_s (i32.add (local.get $pos) (local.get $i)))
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
