;; Shared singletons (nil-free booleans, empty arrays, the format buffer),
;; truthiness, and number access: int/float tests, boxing and unboxing.

  ;; --- singletons ---
  (global $g_true  (ref $LuaBool) (struct.new $LuaBool (i32.const 1)))
  (global $g_false (ref $LuaBool) (struct.new $LuaBool (i32.const 0)))
  (global $g_empty_upvals (ref $UpvalArr) (array.new_fixed $UpvalArr 0))
  (global $g_empty_args   (ref $ArgArr)   (array.new_fixed $ArgArr 0))
  ;; Scratch byte buffer that host_fmt writes into (set up by stdlib_init).
  (global $fmt_buf (mut (ref null $LuaArr)) (ref.null $LuaArr))
  ;; Codegen emits these constants as immutable const-init globals rather
  ;; than this file declaring them, so DCE drops the ones nothing reads (e.g.
  ;; $g_mkey_add once $lua_add is dead): the empty string $g_empty_str, the
  ;; Lua-style source name $g_src_name ("main" for main.lua), the
  ;; metamethod-name keys $g_mkey_* and the type names $g_tname_*.

  ;; --- truthiness: only nil and false are falsy ---
  (func $lua_truthy (param $v anyref) (result i32)
    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then (return (struct.get $LuaBool $b
               (ref.cast (ref $LuaBool) (local.get $v))))))
    (i32.const 1))

  (func $lua_bool_to_ref (param $b i32) (result anyref)
    (if (result anyref) (local.get $b)
      (then (global.get $g_true))
      (else (global.get $g_false))))

  ;; --- numeric type predicates and accessors ---
  (func $is_int (param $v anyref) (result i32)
    (if (result i32) (ref.test (ref i31) (local.get $v))
      (then (i32.const 1))
      (else (ref.test (ref $LuaInt) (local.get $v)))))

  (func $is_float (param $v anyref) (result i32)
    (ref.test (ref $LuaFloat) (local.get $v)))

  (func $as_int (param $v anyref) (result i64)
    (if (result i64) (ref.test (ref i31) (local.get $v))
      (then (i64.extend_i32_s
              (i31.get_s (ref.cast (ref i31) (local.get $v)))))
      (else (struct.get $LuaInt $v
              (ref.cast (ref $LuaInt) (local.get $v))))))

  (func $as_float (param $v anyref) (result f64)
    (if (result f64) (call $is_float (local.get $v))
      (then (struct.get $LuaFloat $v
              (ref.cast (ref $LuaFloat) (local.get $v))))
      (else (f64.convert_i64_s (call $as_int (local.get $v))))))

  (func $make_int (param $v i64) (result anyref)
    (if (result anyref)
      (i32.and
        (i64.ge_s (local.get $v) (i64.const -1073741824))
        (i64.lt_s (local.get $v) (i64.const  1073741824)))
      (then (ref.i31 (i32.wrap_i64 (local.get $v))))
      (else (struct.new $LuaInt (local.get $v)))))

  ;; Maybe-typed locals (docs/design/22): classify a Lua value into the
  ;; (tag, i64, f64) triple — tag 1 int, 2 float, 0 anything else (the boxed
  ;; anyref stays the value). One ref.test chain per store instead of one per
  ;; use.
  ;; Kept in one piece on purpose: splitting the boxed cases out behind a
  ;; return_call (the fast/slow split used elsewhere) measured ~13% slower on
  ;; binarytrees, where every call classifies its parameter here.
  (func $unbox_num (param $v anyref) (result i32 i64 f64)
    (if (ref.test (ref i31) (local.get $v))
      (then (return (i32.const 1)
                    (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $v))))
                    (f64.const 0))))
    (if (ref.test (ref $LuaInt) (local.get $v))
      (then (return (i32.const 1)
                    (struct.get $LuaInt $v (ref.cast (ref $LuaInt) (local.get $v)))
                    (f64.const 0))))
    (if (ref.test (ref $LuaFloat) (local.get $v))
      (then (return (i32.const 2) (i64.const 0)
                    (struct.get $LuaFloat $v (ref.cast (ref $LuaFloat) (local.get $v))))))
    (return (i32.const 0) (i64.const 0) (f64.const 0)))


  ;; The inverse: a maybe-typed triple back to a Lua value (allocates only for
  ;; a float or a wide int).
  (func $box_num (param $tag i32) (param $i i64) (param $f f64) (param $b anyref) (result anyref)
    (if (i32.eq (local.get $tag) (i32.const 1))
      (then (return (call $make_int (local.get $i)))))
    (if (i32.eq (local.get $tag) (i32.const 2))
      (then (return (call $make_float (local.get $f)))))
    (local.get $b))

  (func $make_float (param $v f64) (result anyref)
    (struct.new $LuaFloat (local.get $v)))
