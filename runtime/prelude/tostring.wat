;; Conversions to strings (tostring, number formatting, type names) and
;; concatenation.

  (func $int_to_bytes (param $v i64) (result (ref $LuaArr))
    (local $neg i32) (local $u i64) (local $n i32) (local $out (ref $LuaArr)) (local $i i32)
    ;; Magnitude as unsigned (so mininteger's negation is exact), its digit
    ;; count, then the digits written backwards into the one result array.
    (local.set $u (local.get $v))
    (if (i64.lt_s (local.get $v) (i64.const 0))
      (then
        (local.set $neg (i32.const 1))
        (local.set $u (i64.sub (i64.const 0) (local.get $v)))))
    (local.set $n (i32.const 1))
    (block $counted (loop $cnt
      (br_if $counted (i64.lt_u (local.get $u) (i64.const 10)))
      (local.set $u (i64.div_u (local.get $u) (i64.const 10)))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $cnt)))
    (local.set $out (array.new $LuaArr (i32.const 45) (i32.add (local.get $n) (local.get $neg))))
    (local.set $u (if (result i64) (local.get $neg)
      (then (i64.sub (i64.const 0) (local.get $v))) (else (local.get $v))))
    (local.set $i (i32.sub (i32.add (local.get $n) (local.get $neg)) (i32.const 1)))
    (loop $lp
      (array.set $LuaArr (local.get $out) (local.get $i)
        (i32.add (i32.wrap_i64 (i64.rem_u (local.get $u) (i64.const 10))) (i32.const 48)))
      (local.set $u (i64.div_u (local.get $u) (i64.const 10)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br_if $lp (i64.ne (local.get $u) (i64.const 0))))
    (local.get $out))

  ;; Float-to-bytes via host_fmt kind=6 (Lua tostring style: "1.0" for
  ;; integer-valued floats, %.14g w/ trailing-zero trim otherwise).
  (func $float_to_bytes (param $v f64) (result (ref $LuaArr))
    (local $n i32) (local $out (ref $LuaArr))
    (local.set $n (call $host_fmt (i32.const 6) (i64.const 0)
                       (local.get $v) (i32.const -1)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)
      (ref.as_non_null (global.get $fmt_buf)) (i32.const 0) (local.get $n))
    (local.get $out))

  ;; Lowercase hex digits of a non-negative i32 (minimal width, "0" for 0).
  (func $int_to_hex_bytes (param $v i32) (result (ref $LuaArr))
    (local $n i32) (local $tmp i32) (local $out (ref $LuaArr))
    (local $i i32) (local $d i32)
    (local.set $tmp (local.get $v))
    (local.set $n (i32.const 1))
    (block $cnt (loop $cl
      (local.set $tmp (i32.shr_u (local.get $tmp) (i32.const 4)))
      (br_if $cnt (i32.eqz (local.get $tmp)))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $cl)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (local.set $tmp (local.get $v))
    (local.set $i (i32.sub (local.get $n) (i32.const 1)))
    (block $done (loop $wl
      (local.set $d (i32.and (local.get $tmp) (i32.const 15)))
      (array.set $LuaArr (local.get $out) (local.get $i)
        (if (result i32) (i32.lt_u (local.get $d) (i32.const 10))
          (then (i32.add (local.get $d) (i32.const 48)))     ;; '0'..'9'
          (else (i32.add (local.get $d) (i32.const 87)))))   ;; 'a'..'f'
      (local.set $tmp (i32.shr_u (local.get $tmp) (i32.const 4)))
      (br_if $done (i32.eqz (local.get $i)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $wl)))
    (local.get $out))

  ;; Basic type-name bytes for a value: nil/boolean/number/string/table/
  ;; function. Shared by $builtin_type, $objtypename, and error formatting.
  (func $basic_type_bytes (param $v anyref) (result (ref $LuaArr))
    (if (ref.is_null (local.get $v))
      (then (return (call $bytes_of_lit (i32.const 19)))))            ;; nil
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then (return (call $bytes_of_lit (i32.const 7)))))             ;; boolean
    (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
      (then (return (call $bytes_of_lit (i32.const 0)))))             ;; number
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return (call $bytes_of_lit (i32.const 1)))))             ;; string
    (if (ref.test (ref $LuaTable) (local.get $v))
      (then (return (call $bytes_of_lit (i32.const 2)))))             ;; table
    (call $bytes_of_lit (i32.const 3)))                               ;; function

  ;; The basic type name of a value as a shared constant string ($g_tname_*,
  ;; emitted by codegen with the metamethod keys): what type() returns.
  (func $basic_type_name (param $v anyref) (result (ref $LuaString))
    (if (ref.is_null (local.get $v)) (then (return (global.get $g_tname_nil))))
    (if (ref.test (ref $LuaBool) (local.get $v)) (then (return (global.get $g_tname_boolean))))
    (if (i32.or (call $is_int (local.get $v)) (call $is_float (local.get $v)))
      (then (return (global.get $g_tname_number))))
    (if (ref.test (ref $LuaString) (local.get $v)) (then (return (global.get $g_tname_string))))
    (if (ref.test (ref $LuaTable) (local.get $v)) (then (return (global.get $g_tname_table))))
    (global.get $g_tname_function))

  ;; Like $basic_type_bytes, but a table whose metatable carries a string
  ;; __name field uses that name instead — matching reference Lua's
  ;; luaT_objtypename (used by tostring and type-aware error messages).
  (func $objtypename (param $v anyref) (result (ref $LuaArr))
    (local $nm anyref)
    (local.set $nm (call $get_metamethod (local.get $v)
      (ref.as_non_null (global.get $g_mkey_name))))
    (if (ref.test (ref $LuaString) (local.get $nm))
      (then (return (struct.get $LuaString $bytes
        (ref.cast (ref $LuaString) (local.get $nm))))))
    (call $basic_type_bytes (local.get $v)))

  ;; Build "<prefix>: 0x<hex id>" — the address-style string Lua uses for
  ;; tables/functions/etc. $prefix is the type/name bytes.
  (func $obj_addr_string (param $prefix (ref $LuaArr)) (param $id i32)
                         (result (ref $LuaString))
    (ref.cast (ref $LuaString) (call $lua_concat
      (call $lua_concat
        (struct.new $LuaString (local.get $prefix) (i32.const 0))
        (struct.new $LuaString (array.new_fixed $LuaArr 4
          (i32.const 58) (i32.const 32) (i32.const 48) (i32.const 120)) (i32.const 0)))  ;; ": 0x"
      (struct.new $LuaString (call $int_to_hex_bytes (local.get $id)) (i32.const 0)))))

  (func $lua_tostring (param $v anyref) (result (ref $LuaString))
    (local $mm anyref) (local $r anyref)
    ;; Honour __tostring on any value with a metatable.
    (local.set $mm (call $get_metamethod (local.get $v)
      (ref.as_non_null (global.get $g_mkey_tostring))))
    (if (i32.eqz (ref.is_null (local.get $mm)))
      (then
        (local.set $r
          (call $call_mm1 (local.get $mm) (local.get $v) (ref.null any) (ref.null any) (i32.const 1)))
        (if (i32.eqz (ref.test (ref $LuaString) (local.get $r)))
          (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 508) (i32.const 33)) (i32.const 0)))))
        (return (ref.cast (ref $LuaString) (local.get $r)))))
    (if (ref.is_null (local.get $v))
      (then (return (struct.new $LuaString
        (array.new_data $LuaArr $str_data (i32.const 0) (i32.const 3)) (i32.const 0)))))
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then (return (if (result (ref $LuaString))
        (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v)))
        (then (struct.new $LuaString
          (array.new_data $LuaArr $str_data (i32.const 3) (i32.const 4)) (i32.const 0)))
        (else (struct.new $LuaString
          (array.new_data $LuaArr $str_data (i32.const 7) (i32.const 5)) (i32.const 0)))))))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return (ref.cast (ref $LuaString) (local.get $v)))))
    (if (call $is_int (local.get $v))
      (then (return (struct.new $LuaString
        (call $int_to_bytes (call $as_int (local.get $v))) (i32.const 0)))))
    (if (call $is_float (local.get $v))
      (then (return (struct.new $LuaString
        (call $float_to_bytes (call $as_float (local.get $v))) (i32.const 0)))))
    ;; tables and functions: "type: 0x<addr>". The data segment layout (see
    ;; codegen) is: niltruefalse<float>numberstringtablefunction...
    ;;               0    3    7   12     19    25   31   36
    ;; Tables use their unique $id so distinct tables stringify distinctly,
    ;; matching reference. Closures have no per-object id, so they share a
    ;; constant address (the "function:" prefix is what callers check; their
    ;; mutual distinctness is a documented minor gap).
    (if (ref.test (ref $LuaTable) (local.get $v))
      (then (return (call $obj_addr_string (call $objtypename (local.get $v))
        (struct.get $LuaTable $id (ref.cast (ref $LuaTable) (local.get $v)))))))   ;; "table" or __name
    (if (ref.test (ref $LuaClosure) (local.get $v))
      (then (return (call $obj_addr_string
        (array.new_data $LuaArr $str_data (i32.const 36) (i32.const 8))
        (call $host_obj_id (local.get $v))))))   ;; "function"
    ;; Unknown type: nil placeholder so we never trap.
    (struct.new $LuaString
      (array.new_data $LuaArr $str_data (i32.const 0) (i32.const 3)) (i32.const 0)))

  ;; Per Lua, `..` only accepts string or number operands directly;
  ;; anything else falls through to $arith_mm with $g_mkey_concat in
  ;; $lua_concat below.
  (func $is_concatable (param $v anyref) (result i32)
    (i32.or (ref.test (ref $LuaString) (local.get $v))
            (i32.or (call $is_int (local.get $v))
                    (call $is_float (local.get $v)))))

  ;; Bytes of a concat operand. Precondition: $is_concatable (string/int/float)
  ;; — so unlike $lua_tostring this skips the __tostring metamethod probe and,
  ;; for numbers, the throwaway $LuaString wrapper (`..` never consults
  ;; __tostring, matching reference). Strings hand back their backing array.
  (func $concat_bytes (param $v anyref) (result (ref $LuaArr))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return (struct.get $LuaString $bytes
        (ref.cast (ref $LuaString) (local.get $v))))))
    (if (call $is_int (local.get $v))
      (then (return (call $int_to_bytes (call $as_int (local.get $v))))))
    (call $float_to_bytes (call $as_float (local.get $v))))

  (func $lua_concat (param $a anyref) (param $b anyref) (result anyref)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr)) (local $out (ref $LuaArr))
    (local $na i32) (local $nb i32)
    (if (i32.eqz (i32.and (call $is_concatable (local.get $a))
                          (call $is_concatable (local.get $b))))
      (then (return (call $arith_mm (local.get $a) (local.get $b)
                      (ref.as_non_null (global.get $g_mkey_concat))))))
    (local.set $sa (call $concat_bytes (local.get $a)))
    (local.set $sb (call $concat_bytes (local.get $b)))
    (local.set $na (array.len (local.get $sa)))
    (local.set $nb (array.len (local.get $sb)))
    ;; Raise a Lua-level "too large" before wasm traps on array.new for
    ;; a multi-gigabyte buffer — heavy.lua relies on pcall catching this.
    (if (i32.lt_s (i32.add (local.get $na) (local.get $nb)) (i32.const 0))
      (then (call $throw_lit (i32.const 297) (i32.const 9))))     ;; "too large"
    (local.set $out (array.new $LuaArr (i32.const 0)
                       (i32.add (local.get $na) (local.get $nb))))
    (array.copy $LuaArr $LuaArr
      (local.get $out) (i32.const 0)
      (local.get $sa)  (i32.const 0) (local.get $na))
    (array.copy $LuaArr $LuaArr
      (local.get $out) (local.get $na)
      (local.get $sb)  (i32.const 0) (local.get $nb))
    (struct.new $LuaString (local.get $out) (i32.const 0)))

  ;; `a .. b .. c` / `a .. b .. c .. d` in one allocation: codegen flattens a
  ;; right-nested chain, whose operands are already evaluated left to right.
  ;; When one isn't a string or number the chain is concatenated pairwise from
  ;; the right, as reference Lua does, so __concat sees the same calls.
  (func $lua_concat3 (param $a anyref) (param $b anyref) (param $c anyref) (result anyref)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr)) (local $sc (ref $LuaArr))
    (local $out (ref $LuaArr)) (local $n i64)
    (if (i32.eqz (i32.and (call $is_concatable (local.get $a))
                          (i32.and (call $is_concatable (local.get $b)) (call $is_concatable (local.get $c)))))
      (then (return (call $lua_concat (local.get $a) (call $lua_concat (local.get $b) (local.get $c))))))
    (local.set $sa (call $concat_bytes (local.get $a)))
    (local.set $sb (call $concat_bytes (local.get $b)))
    (local.set $sc (call $concat_bytes (local.get $c)))
    (local.set $n (i64.add (i64.extend_i32_u (array.len (local.get $sa)))
                  (i64.add (i64.extend_i32_u (array.len (local.get $sb)))
                           (i64.extend_i32_u (array.len (local.get $sc))))))
    (if (i64.gt_u (local.get $n) (i64.const 2147483647))
      (then (call $throw_lit (i32.const 297) (i32.const 9))))     ;; "too large"
    (local.set $out (array.new $LuaArr (i32.const 0) (i32.wrap_i64 (local.get $n))))
    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)
      (local.get $sa) (i32.const 0) (array.len (local.get $sa)))
    (array.copy $LuaArr $LuaArr (local.get $out) (array.len (local.get $sa))
      (local.get $sb) (i32.const 0) (array.len (local.get $sb)))
    (array.copy $LuaArr $LuaArr (local.get $out)
      (i32.add (array.len (local.get $sa)) (array.len (local.get $sb)))
      (local.get $sc) (i32.const 0) (array.len (local.get $sc)))
    (struct.new $LuaString (local.get $out) (i32.const 0)))
  (func $lua_concat4 (param $a anyref) (param $b anyref) (param $c anyref) (param $d anyref) (result anyref)
    (local $sa (ref $LuaArr)) (local $sb (ref $LuaArr)) (local $sc (ref $LuaArr)) (local $sd (ref $LuaArr))
    (local $out (ref $LuaArr)) (local $n i64) (local $p i32)
    (if (i32.eqz (i32.and (i32.and (call $is_concatable (local.get $a)) (call $is_concatable (local.get $b)))
                          (i32.and (call $is_concatable (local.get $c)) (call $is_concatable (local.get $d)))))
      (then (return (call $lua_concat (local.get $a)
        (call $lua_concat (local.get $b) (call $lua_concat (local.get $c) (local.get $d)))))))
    (local.set $sa (call $concat_bytes (local.get $a)))
    (local.set $sb (call $concat_bytes (local.get $b)))
    (local.set $sc (call $concat_bytes (local.get $c)))
    (local.set $sd (call $concat_bytes (local.get $d)))
    (local.set $n (i64.add (i64.add (i64.extend_i32_u (array.len (local.get $sa)))
                                    (i64.extend_i32_u (array.len (local.get $sb))))
                           (i64.add (i64.extend_i32_u (array.len (local.get $sc)))
                                    (i64.extend_i32_u (array.len (local.get $sd))))))
    (if (i64.gt_u (local.get $n) (i64.const 2147483647))
      (then (call $throw_lit (i32.const 297) (i32.const 9))))     ;; "too large"
    (local.set $out (array.new $LuaArr (i32.const 0) (i32.wrap_i64 (local.get $n))))
    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0)
      (local.get $sa) (i32.const 0) (array.len (local.get $sa)))
    (local.set $p (array.len (local.get $sa)))
    (array.copy $LuaArr $LuaArr (local.get $out) (local.get $p)
      (local.get $sb) (i32.const 0) (array.len (local.get $sb)))
    (local.set $p (i32.add (local.get $p) (array.len (local.get $sb))))
    (array.copy $LuaArr $LuaArr (local.get $out) (local.get $p)
      (local.get $sc) (i32.const 0) (array.len (local.get $sc)))
    (local.set $p (i32.add (local.get $p) (array.len (local.get $sc))))
    (array.copy $LuaArr $LuaArr (local.get $out) (local.get $p)
      (local.get $sd) (i32.const 0) (array.len (local.get $sd)))
    (struct.new $LuaString (local.get $out) (i32.const 0)))

  ;; bytes_of_lit: looks up a built-in literal name (`number`, `string`, etc.)
  ;; by index into the type-name slab. Indices into the slab:
  ;;   0  "number"     (6 bytes)
  ;;   1  "string"     (6 bytes)
  ;;   2  "table"      (5 bytes)
  ;;   3  "function"   (8 bytes)
  ;;   7  "boolean"    (7 bytes, overlaps the prefix region)
  ;;   19 "nil"        (3 bytes)
  ;;
  ;; The slab is the same `$str_data` segment used by $lua_tostring. We
  ;; carefully reserve names at known offsets in codegen_module.
  (func $bytes_of_lit (param $idx i32) (result (ref $LuaArr))
    (block $r (result (ref $LuaArr))
      (if (i32.eq (local.get $idx) (i32.const 0))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 19) (i32.const 6)))))
      (if (i32.eq (local.get $idx) (i32.const 1))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 25) (i32.const 6)))))
      (if (i32.eq (local.get $idx) (i32.const 2))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 31) (i32.const 5)))))
      (if (i32.eq (local.get $idx) (i32.const 3))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 36) (i32.const 8)))))
      (if (i32.eq (local.get $idx) (i32.const 7))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 44) (i32.const 7)))))
      (if (i32.eq (local.get $idx) (i32.const 19))
        (then (br $r (array.new_data $LuaArr $str_data (i32.const 0) (i32.const 3)))))   ;; nil
      ;; Every caller passes one of the constants above (0/1/2/3/7/19, the
      ;; type-name literals). Trap on a stray index rather than silently
      ;; handing back the wrong slab bytes, so a future bad caller is caught.
      (unreachable)))
