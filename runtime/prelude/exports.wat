;; Exports for the JS host: decoding values and reading runtime state.

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
  ;; Read up to four bytes starting at $i, packed little-endian into an i32
  ;; (bytes past the end read as 0). Lets the host pull a Lua string out in
  ;; word-sized steps, cutting the JS<->wasm crossings per string ~4x versus
  ;; one $lua_str_byte call per byte. (No linear memory, so a true bulk copy
  ;; of the (array i8) into a JS view isn't available; a packed scalar is.)
  (func (export "lua_str_word") (param $v anyref) (param $i i32) (result i32)
    (local $a (ref $LuaArr)) (local $n i32) (local $w i32)
    (local.set $a
      (struct.get $LuaString $bytes (ref.cast (ref $LuaString) (local.get $v))))
    (local.set $n (array.len (local.get $a)))
    (if (i32.lt_u (local.get $i) (local.get $n))
      (then (local.set $w (array.get_u $LuaArr (local.get $a) (local.get $i)))))
    (if (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (local.get $n))
      (then (local.set $w (i32.or (local.get $w) (i32.shl
        (array.get_u $LuaArr (local.get $a) (i32.add (local.get $i) (i32.const 1)))
        (i32.const 8))))))
    (if (i32.lt_u (i32.add (local.get $i) (i32.const 2)) (local.get $n))
      (then (local.set $w (i32.or (local.get $w) (i32.shl
        (array.get_u $LuaArr (local.get $a) (i32.add (local.get $i) (i32.const 2)))
        (i32.const 16))))))
    (if (i32.lt_u (i32.add (local.get $i) (i32.const 3)) (local.get $n))
      (then (local.set $w (i32.or (local.get $w) (i32.shl
        (array.get_u $LuaArr (local.get $a) (i32.add (local.get $i) (i32.const 3)))
        (i32.const 24))))))
    (local.get $w))
  ;; Host-callable constructors so JS can build int/float values from
  ;; parsed strings (used by tonumber).
  (func (export "lua_make_int") (param $v i64) (result anyref)
    (call $make_int (local.get $v)))
  (func (export "lua_make_float") (param $v f64) (result anyref)
    (call $make_float (local.get $v)))
  ;; JS-side writer for the format scratch buffer.
  (func (export "fmt_buf_set") (param $i i32) (param $b i32)
    (array.set $LuaArr (ref.as_non_null (global.get $fmt_buf))
      (local.get $i) (local.get $b)))
  ;; Four packed little-endian bytes at once (the host's bulk writer): one
  ;; JS->wasm crossing per word instead of per byte. Bytes past $n are not
  ;; written, so the tail of a string needs no host-side guard.
  (func (export "fmt_buf_set_word") (param $i i32) (param $w i32) (param $n i32)
    (local $buf (ref $LuaArr))
    (local.set $buf (ref.as_non_null (global.get $fmt_buf)))
    (array.set $LuaArr (local.get $buf) (local.get $i) (local.get $w))
    (if (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (local.get $n))
      (then (array.set $LuaArr (local.get $buf) (i32.add (local.get $i) (i32.const 1))
              (i32.shr_u (local.get $w) (i32.const 8)))))
    (if (i32.lt_u (i32.add (local.get $i) (i32.const 2)) (local.get $n))
      (then (array.set $LuaArr (local.get $buf) (i32.add (local.get $i) (i32.const 2))
              (i32.shr_u (local.get $w) (i32.const 16)))))
    (if (i32.lt_u (i32.add (local.get $i) (i32.const 3)) (local.get $n))
      (then (array.set $LuaArr (local.get $buf) (i32.add (local.get $i) (i32.const 3))
              (i32.shr_u (local.get $w) (i32.const 24))))))

  ;; Error-context probes for the host's uncaught-exception path. On a
  ;; thrown $LuaError the call-frame stack is left intact (pop is skipped
  ;; on throw), so reading the topmost frame here yields the source line
  ;; at the throw site — useful even when the payload is nil.
  (func (export "lua_error_line") (result i32)
    (if (result i32)
        (i32.and
          (i32.gt_s (global.get $call_depth) (i32.const 0))
          (i32.eqz (ref.is_null (global.get $call_lines))))
      (then (array.get $LineArr
              (ref.as_non_null (global.get $call_lines))
              (i32.sub (global.get $call_depth) (i32.const 1))))
      (else (i32.const 0))))
  (func (export "lua_src_name") (result anyref)
    (global.get $g_src_name))
