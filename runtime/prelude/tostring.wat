;; Conversions to strings (tostring, number formatting, type names) and
;; concatenation.

;; The decimal form of an integer: $int_len counts its bytes (sign
  ;; included) and $int_write writes them into $out, ending at $end. The
  ;; magnitude is taken as unsigned, so mininteger's negation is exact.
  (func $int_len (param $v i64) (result i32)
    (local $u i64) (local $n i32)
    (local.set $n (i32.const 1))
    (local.set $u (local.get $v))
    (if (i64.lt_s (local.get $v) (i64.const 0))
      (then
        (local.set $n (i32.const 2))
        (local.set $u (i64.sub (i64.const 0) (local.get $v)))))
    (block $counted (loop $cnt
      (br_if $counted (i64.lt_u (local.get $u) (i64.const 10)))
      (local.set $u (i64.div_u (local.get $u) (i64.const 10)))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $cnt)))
    (local.get $n))
  (func $int_write (param $out (ref $LuaArr)) (param $end i32) (param $v i64)
    (local $u i64) (local $i i32)
    (local.set $u (local.get $v))
    (if (i64.lt_s (local.get $v) (i64.const 0))
      (then (local.set $u (i64.sub (i64.const 0) (local.get $v)))))
    (local.set $i (local.get $end))
    (loop $lp
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (array.set $LuaArr (local.get $out) (local.get $i)
        (i32.add (i32.wrap_i64 (i64.rem_u (local.get $u) (i64.const 10))) (i32.const 48)))
      (local.set $u (i64.div_u (local.get $u) (i64.const 10)))
      (br_if $lp (i64.ne (local.get $u) (i64.const 0))))
    (if (i64.lt_s (local.get $v) (i64.const 0))
      (then (array.set $LuaArr (local.get $out) (i32.sub (local.get $i) (i32.const 1)) (i32.const 45)))))
  (func $int_to_bytes (param $v i64) (result (ref $LuaArr))
    (local $n i32) (local $out (ref $LuaArr))
    (local.set $n (call $int_len (local.get $v)))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $n)))
    (call $int_write (local.get $out) (local.get $n) (local.get $v))
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
      (then (return (call $str_bytes
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
      (then (return (call $str_of_bytes (call $int_to_bytes (call $as_int (local.get $v))) (i32.const 3)))))
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

;; The short-string cache. A string of at most 40 bytes made at run time
  ;; (a match or capture, string.sub, a short `..` result, an integer's
  ;; digits) is looked up first in a direct-mapped cache of 4096 strings,
  ;; indexed by its hash: an equal string there is returned instead of a new
  ;; one, so a program that makes the same short strings over and over —
  ;; words, keys, tokens — allocates each once, keeps one copy alive, and its
  ;; table lookups find the key by identity. A miss makes the string (its hash
  ;; already computed, as a table key needs) and puts it in the slot, in place
  ;; of whatever was there. Being lossy, the cache needs no weak references:
  ;; it holds at most 4096 short strings alive, whatever the program makes.
  ;; A probe costs more than the allocation it saves, and a miss also
  ;; stores the string, so the cache only pays where most probes hit. It is
  ;; adaptive per kind of string ($kind: 0 a `..` result, 1 string.sub, 2 a
  ;; match or capture, 3 an integer's digits): when more than half of a
  ;; window of 256 probes missed, the kind skips the cache for its next 4096
  ;; strings, then probes again. A program making unique strings of a kind —
  ;; or more distinct ones than the cache holds, like the coordinates of a
  ;; large grid — probes ~6% of them; one repeating a few keeps hitting.
  (global $g_scache (ref $StrCache) (array.new_default $StrCache (i32.const 4096)))
  ;; per kind: [4k] probes in this window, [4k+1] misses in it, [4k+2]
  ;; strings left to make uncached
  (global $g_scache_state (ref $IArr) (array.new_default $IArr (i32.const 16)))
  ;; A one-byte string needs no hash: there are 256 of them, each made once.
  (global $g_char_strs (ref $StrCache) (array.new_default $StrCache (i32.const 256)))
  (func $char_str (param $b i32) (result (ref $LuaString))
    (local $c (ref null $LuaString)) (local $s (ref $LuaString))
    (local.set $c (array.get $StrCache (global.get $g_char_strs) (local.get $b)))
    (if (i32.eqz (ref.is_null (local.get $c))) (then (return (ref.as_non_null (local.get $c)))))
    (local.set $s (struct.new $LuaString (array.new $LuaArr (local.get $b) (i32.const 1))
      (call $hash_range (array.new $LuaArr (local.get $b) (i32.const 1)) (i32.const 0) (i32.const 1))))
    (array.set $StrCache (global.get $g_char_strs) (local.get $b) (local.get $s))
    (local.get $s))
  ;; 1 if this string of $kind should probe the cache.
  (func $scache_on (param $kind i32) (result i32)
    (local $st (ref $IArr)) (local $k i32) (local $skip i32) (local $p i32)
    (local.set $st (global.get $g_scache_state))
    (local.set $k (i32.shl (local.get $kind) (i32.const 2)))
    (local.set $skip (array.get $IArr (local.get $st) (i32.add (local.get $k) (i32.const 2))))
    (if (local.get $skip)
      (then (array.set $IArr (local.get $st) (i32.add (local.get $k) (i32.const 2))
                       (i32.sub (local.get $skip) (i32.const 1)))
            (return (i32.const 0))))
    (local.set $p (i32.add (array.get $IArr (local.get $st) (local.get $k)) (i32.const 1)))
    (if (i32.lt_u (local.get $p) (i32.const 256))
      (then (array.set $IArr (local.get $st) (local.get $k) (local.get $p))
            (return (i32.const 1))))
    ;; the window is full: pause the kind if most of it missed
    (if (i32.gt_u (array.get $IArr (local.get $st) (i32.add (local.get $k) (i32.const 1))) (i32.const 128))
      (then (array.set $IArr (local.get $st) (i32.add (local.get $k) (i32.const 2)) (i32.const 4096))))
    (array.set $IArr (local.get $st) (local.get $k) (i32.const 0))
    (array.set $IArr (local.get $st) (i32.add (local.get $k) (i32.const 1)) (i32.const 0))
    (i32.const 1))
  ;; A probe of $kind missed.
  (func $scache_missed (param $kind i32)
    (local $st (ref $IArr)) (local $k i32)
    (local.set $st (global.get $g_scache_state))
    (local.set $k (i32.add (i32.shl (local.get $kind) (i32.const 2)) (i32.const 1)))
    (array.set $IArr (local.get $st) (local.get $k)
      (i32.add (array.get $IArr (local.get $st) (local.get $k)) (i32.const 1))))
  ;; The cache slot of $src[$start .. $start + $len) (2 <= $len <= 40): from
  ;; its length and five of its bytes, which are independent loads where the
  ;; table hash is a chain of multiplies through every byte. Strings alike in
  ;; those only compete for a slot; the probe compares every byte.
  (func $scache_slot (param $src (ref $LuaArr)) (param $start i32) (param $len i32) (result i32)
    (local $end i32)
    (local.set $end (i32.add (local.get $start) (local.get $len)))
    (i32.shr_u
      (i32.mul
        (i32.xor
          (i32.xor (i32.mul (local.get $len) (i32.const -1640531535))
                   (i32.or (array.get_u $LuaArr (local.get $src) (local.get $start))
                           (i32.shl (array.get_u $LuaArr (local.get $src)
                                      (i32.add (local.get $start) (i32.const 1))) (i32.const 8))))
          (i32.or (i32.shl (array.get_u $LuaArr (local.get $src)
                             (i32.add (local.get $start) (i32.shr_u (local.get $len) (i32.const 1))))
                           (i32.const 16))
                  (i32.or (i32.shl (array.get_u $LuaArr (local.get $src) (i32.sub (local.get $end) (i32.const 2)))
                                   (i32.const 24))
                          (i32.rotl (array.get_u $LuaArr (local.get $src) (i32.sub (local.get $end) (i32.const 1)))
                                    (i32.const 4)))))
        (i32.const -2048144789))
      (i32.const 20)))
  ;; The cached string equal to $src[$start .. $start + $len) in $slot, or null.
  (func $scache_find (param $src (ref $LuaArr)) (param $start i32) (param $len i32) (param $slot i32)
                     (result (ref null $LuaString))
    (local $c (ref null $LuaString)) (local $cb (ref $LuaArr)) (local $i i32)
    (local.set $c (array.get $StrCache (global.get $g_scache) (local.get $slot)))
    (if (ref.is_null (local.get $c)) (then (return (ref.null $LuaString))))
    (local.set $cb (call $str_bytes (local.get $c)))
    (if (i32.ne (array.len (local.get $cb)) (local.get $len)) (then (return (ref.null $LuaString))))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
      (if (i32.ne (array.get_u $LuaArr (local.get $cb) (local.get $i))
                  (array.get_u $LuaArr (local.get $src) (i32.add (local.get $start) (local.get $i))))
        (then (return (ref.null $LuaString))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $c))
  ;; The string of $src[$start .. $start + $len), through the cache: nothing
  ;; is allocated when it hits.
  (func $str_from_range (param $src (ref $LuaArr)) (param $start i32) (param $len i32) (param $kind i32)
                        (result (ref $LuaString))
    (local $slot i32) (local $c (ref null $LuaString)) (local $out (ref $LuaArr)) (local $s (ref $LuaString))
    (local $on i32)
    (if (i32.eq (local.get $len) (i32.const 1))
      (then (return (call $char_str (array.get_u $LuaArr (local.get $src) (local.get $start))))))
    (if (i32.and (i32.le_u (local.get $len) (i32.const 40)) (i32.ge_u (local.get $len) (i32.const 2)))
      (then (local.set $on (call $scache_on (local.get $kind)))))
    (if (local.get $on)
      (then
        (local.set $slot (call $scache_slot (local.get $src) (local.get $start) (local.get $len)))
        (local.set $c (call $scache_find (local.get $src) (local.get $start) (local.get $len) (local.get $slot)))
        (if (i32.eqz (ref.is_null (local.get $c))) (then (return (ref.as_non_null (local.get $c)))))))
    (local.set $out (array.new $LuaArr (i32.const 0) (local.get $len)))
    (array.copy $LuaArr $LuaArr (local.get $out) (i32.const 0) (local.get $src) (local.get $start) (local.get $len))
    (if (i32.eqz (local.get $on))
      (then (return (struct.new $LuaString (local.get $out) (i32.const 0)))))
    (call $scache_missed (local.get $kind))
    (local.set $s (struct.new $LuaString (local.get $out) (i32.const 0)))
    (array.set $StrCache (global.get $g_scache) (local.get $slot) (local.get $s))
    (local.get $s))
  ;; The string of the bytes $out (a fresh array, which becomes the string's
  ;; own), through the cache.
  (func $str_of_bytes (param $out (ref $LuaArr)) (param $kind i32) (result (ref $LuaString))
    (local $n i32) (local $slot i32) (local $c (ref null $LuaString)) (local $s (ref $LuaString))
    (local.set $n (array.len (local.get $out)))
    (if (i32.gt_u (local.get $n) (i32.const 40))
      (then (return (struct.new $LuaString (local.get $out) (i32.const 0)))))
    (if (i32.eq (local.get $n) (i32.const 1))
      (then (return (call $char_str (array.get_u $LuaArr (local.get $out) (i32.const 0))))))
    (if (i32.or (i32.lt_u (local.get $n) (i32.const 2)) (i32.eqz (call $scache_on (local.get $kind))))
      (then (return (struct.new $LuaString (local.get $out) (i32.const 0)))))
    (local.set $slot (call $scache_slot (local.get $out) (i32.const 0) (local.get $n)))
    (local.set $c (call $scache_find (local.get $out) (i32.const 0) (local.get $n) (local.get $slot)))
    (if (i32.eqz (ref.is_null (local.get $c))) (then (return (ref.as_non_null (local.get $c)))))
    (call $scache_missed (local.get $kind))
    (local.set $s (struct.new $LuaString (local.get $out) (i32.const 0)))
    (array.set $StrCache (global.get $g_scache) (local.get $slot) (local.get $s))
    (local.get $s))

;; Lazy strings. A `..` whose result is at least 128 bytes long (the
  ;; minimum below) doesn't copy its operands into a new array; it makes a
  ;; $LuaLazy string, one of two kinds:
  ;;  - a $LuaRope, a node over the two operands;
  ;;  - a $LuaBufStr, the first $len bytes of a growable $StrBuf. `s .. x`
  ;;    with `s` the buffer's latest version (its $len is the buffer's
  ;;    $used) writes `x` into the spare capacity and makes a new version:
  ;;    an append copies only its piece, and nothing but the buffer and the
  ;;    newest version stays alive.
  ;; An append to a node not yet read (a loop appending without reading)
  ;; starts a buffer; any other long result is a node — so a loop that reads
  ;; its string every step never copies it into a buffer it can't use.
  ;; The first read of the bytes ($str_bytes, which every byte read goes
  ;; through) flattens a lazy string into one exact array, kept in $bytes,
  ;; and drops the node's operands or the buffer (a finished string doesn't
  ;; keep its spare capacity alive). Its length ($str_length, so `#s`) and an
  ;; equality test against a string of another length never flatten it.
  ;; Every lazy string is at least the minimum long, so a shorter result's
  ;; operands are flat.
  ;; (Kept small: V8 inlines it everywhere, and every byte it adds comes out
  ;; of the inlining budget of the function it lands in.)
  (func $str_bytes (param $s (ref null $LuaString)) (result (ref $LuaArr))
    (local $b (ref null $LuaArr))
    (if (ref.is_null (local.tee $b (struct.get $LuaString $bytes (local.get $s))))
      (then (return_call $lazy_flatten (local.get $s))))
    (ref.as_non_null (local.get $b)))
  (func $str_length (param $s (ref $LuaString)) (result i32)
    (local $b (ref null $LuaArr))
    (local.set $b (struct.get $LuaString $bytes (local.get $s)))
    (if (ref.is_null (local.get $b))
      (then (return (struct.get $LuaLazy $len (ref.cast (ref $LuaLazy) (local.get $s))))))
    (array.len (ref.as_non_null (local.get $b))))
  (func $lazy_flatten (param $str (ref null $LuaString)) (result (ref $LuaArr))
    (local $s (ref $LuaLazy)) (local $out (ref $LuaArr))
    (local.set $s (ref.cast (ref $LuaLazy) (local.get $str)))
    (local.set $out (call $lazy_write (ref.null $LuaArr) (struct.get $LuaLazy $len (local.get $s))
                                      (local.get $s)))
    (struct.set $LuaString $bytes (local.get $s) (local.get $out))
    (if (ref.test (ref $LuaRope) (local.get $s))
      (then
        (struct.set $LuaRope $left (ref.cast (ref $LuaRope) (local.get $s)) (ref.null $LuaString))
        (struct.set $LuaRope $right (ref.cast (ref $LuaRope) (local.get $s)) (ref.null $LuaString)))
      (else (struct.set $LuaBufStr $buf (ref.cast (ref $LuaBufStr) (local.get $s)) (ref.null $StrBuf))))
    (local.get $out))
  ;; The bytes of an unread lazy string into $out (a new array of $end
  ;; bytes when null), ending at $end; returns $out. Right to left over the
  ;; leaves: a node continues with its right operand and leaves its left one
  ;; on a stack (which only grows for a rope built by prepending); a flat
  ;; string or a buffer version is a leaf. (The allocation sits here, in the
  ;; function with the loop, which V8 optimizes soon: in the baseline tier
  ;; `array.new` fills its array a byte at a time.)
  (func $lazy_write (param $o (ref null $LuaArr)) (param $end i32) (param $s (ref $LuaLazy))
                    (result (ref $LuaArr))
    (local $out (ref $LuaArr))
    (local $pos i32) (local $n (ref $LuaString)) (local $b (ref null $LuaArr)) (local $len i32)
    (local $node (ref $LuaRope)) (local $stack (ref $TArr)) (local $sp i32) (local $grown (ref $TArr))
    (local.set $out (if (result (ref $LuaArr)) (ref.is_null (local.get $o))
      (then (array.new $LuaArr (i32.const 0) (local.get $end)))
      (else (ref.as_non_null (local.get $o)))))
    (local.set $pos (local.get $end))
    (local.set $stack (array.new $TArr (ref.null any) (i32.const 16)))
    (local.set $n (local.get $s))
    (block $done (loop $lp
      (local.set $b (struct.get $LuaString $bytes (local.get $n)))
      (if (ref.is_null (local.get $b))
        (then
          (if (ref.test (ref $LuaRope) (local.get $n))
            (then
              (local.set $node (ref.cast (ref $LuaRope) (local.get $n)))
              (if (i32.eq (local.get $sp) (array.len (local.get $stack)))
                (then
                  (local.set $grown (array.new $TArr (ref.null any) (i32.shl (local.get $sp) (i32.const 1))))
                  (array.copy $TArr $TArr (local.get $grown) (i32.const 0)
                                          (local.get $stack) (i32.const 0) (local.get $sp))
                  (local.set $stack (local.get $grown))))
              (array.set $TArr (local.get $stack) (local.get $sp) (struct.get $LuaRope $left (local.get $node)))
              (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
              (local.set $n (ref.as_non_null (struct.get $LuaRope $right (local.get $node))))
              (br $lp)))
          (local.set $len (struct.get $LuaLazy $len (ref.cast (ref $LuaLazy) (local.get $n))))
          (local.set $pos (i32.sub (local.get $pos) (local.get $len)))
          (array.copy $LuaArr $LuaArr (local.get $out) (local.get $pos)
            (struct.get $StrBuf $arr (ref.as_non_null
              (struct.get $LuaBufStr $buf (ref.cast (ref $LuaBufStr) (local.get $n)))))
            (i32.const 0) (local.get $len)))
        (else
          (local.set $pos (i32.sub (local.get $pos) (array.len (ref.as_non_null (local.get $b)))))
          (array.copy $LuaArr $LuaArr (local.get $out) (local.get $pos) (ref.as_non_null (local.get $b))
                                      (i32.const 0) (array.len (ref.as_non_null (local.get $b))))))
      (br_if $done (i32.eqz (local.get $sp)))
      (local.set $sp (i32.sub (local.get $sp) (i32.const 1)))
      (local.set $n (ref.cast (ref $LuaString) (array.get $TArr (local.get $stack) (local.get $sp))))
      (br $lp)))
    (local.get $out))

;; A concat operand as a piece of the result (precondition: $is_concatable):
  ;; its bytes and their length — or, for an integer, no bytes and the length
  ;; of its digits, which $concat_put writes straight into the result (no
  ;; array for the digits alone), and for an unread lazy string no bytes
  ;; either (see $concat_lazy). `..` never consults __tostring, matching
  ;; reference Lua.
  (func $concat_piece (param $v anyref) (result (ref null $LuaArr) i32)
    (local $a (ref $LuaArr)) (local $s (ref $LuaString))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then
        (local.set $s (ref.cast (ref $LuaString) (local.get $v)))
        (return (struct.get $LuaString $bytes (local.get $s)) (call $str_length (local.get $s)))))
    (if (call $is_int (local.get $v))
      (then (return (ref.null $LuaArr) (call $int_len (call $as_int (local.get $v))))))
    (local.set $a (call $float_to_bytes (call $as_float (local.get $v))))
    (local.get $a) (array.len (local.get $a)))
  ;; Write a piece ($v, its $bytes and length $n) into $out at $pos; returns
  ;; the position after it. A lazy string among the pieces is flattened for
  ;; it.
  (func $concat_put (param $out (ref $LuaArr)) (param $pos i32) (param $v anyref)
                    (param $bytes (ref null $LuaArr)) (param $n i32) (result i32)
    (if (ref.is_null (local.get $bytes))
      (then (if (ref.test (ref $LuaString) (local.get $v))
        (then (local.set $bytes (call $str_bytes (ref.cast (ref $LuaString) (local.get $v)))))
        (else (call $int_write (local.get $out) (i32.add (local.get $pos) (local.get $n))
                               (call $as_int (local.get $v)))
              (return (i32.add (local.get $pos) (local.get $n)))))))
    (array.copy $LuaArr $LuaArr (local.get $out) (local.get $pos)
                (ref.as_non_null (local.get $bytes)) (i32.const 0) (local.get $n))
    (i32.add (local.get $pos) (local.get $n)))
  ;; The lazy string of two concat operands whose total length $n (at least
  ;; the minimum) the caller has summed: the buffer's next version when $a
  ;; is its latest, a new buffer when $a is a node not yet read, else a node
  ;; (a number operand becomes its string; $sa / $sb: a float's bytes, from
  ;; its piece).
  (func $concat_lazy (param $a anyref) (param $sa (ref null $LuaArr))
                     (param $b anyref) (param $sb (ref null $LuaArr)) (param $n i64) (result anyref)
    (local $bs (ref $LuaBufStr)) (local $buf (ref null $StrBuf))
    (if (i64.gt_u (local.get $n) (i64.const 2147483647))
      (then (call $throw_lit (i32.const 297) (i32.const 9))))     ;; "too large"
    (if (ref.test (ref $LuaBufStr) (local.get $a))
      (then
        (local.set $bs (ref.cast (ref $LuaBufStr) (local.get $a)))
        (local.set $buf (struct.get $LuaBufStr $buf (local.get $bs)))
        (if (i32.eqz (ref.is_null (local.get $buf)))
          (then (if (i32.eq (struct.get $LuaLazy $len (local.get $bs))
                            (struct.get $StrBuf $used (ref.as_non_null (local.get $buf))))
            (then (return (call $buf_append (ref.as_non_null (local.get $buf))
                    (struct.get $LuaLazy $len (local.get $bs))
                    (local.get $b) (local.get $sb) (i32.wrap_i64 (local.get $n))))))))))
    (if (ref.test (ref $LuaRope) (local.get $a))
      (then (if (ref.is_null (struct.get $LuaString $bytes (ref.cast (ref $LuaRope) (local.get $a))))
        (then (return (call $buf_start (ref.cast (ref $LuaRope) (local.get $a))
                (local.get $b) (local.get $sb) (i32.wrap_i64 (local.get $n))))))))
    (struct.new $LuaRope (ref.null $LuaArr) (i32.const 0) (i32.wrap_i64 (local.get $n))
      (call $concat_str (local.get $a) (local.get $sa))
      (call $concat_str (local.get $b) (local.get $sb))))
  ;; Twice the needed capacity (a length is an i32).
  (func $buf_cap (param $n i32) (result i32)
    (if (i32.gt_u (local.get $n) (i32.const 0x3fffffff)) (then (return (i32.const 0x7fffffff))))
    (i32.shl (local.get $n) (i32.const 1)))
  ;; Append $b (piece bytes $sb) to the buffer's latest version, $na long;
  ;; the result is $n long.
  (func $buf_append (param $buf (ref $StrBuf)) (param $na i32)
                    (param $b anyref) (param $sb (ref null $LuaArr)) (param $n i32) (result anyref)
    (local $arr (ref $LuaArr)) (local $grown (ref $LuaArr))
    (local.set $arr (struct.get $StrBuf $arr (local.get $buf)))
    (if (i32.gt_u (local.get $n) (array.len (local.get $arr)))
      (then
        (local.set $grown (array.new $LuaArr (i32.const 0) (call $buf_cap (local.get $n))))
        (array.copy $LuaArr $LuaArr (local.get $grown) (i32.const 0)
                                    (local.get $arr) (i32.const 0) (local.get $na))
        (struct.set $StrBuf $arr (local.get $buf) (local.get $grown))
        (local.set $arr (local.get $grown))))
    (drop (call $concat_put (local.get $arr) (local.get $na) (local.get $b) (local.get $sb)
                            (i32.sub (local.get $n) (local.get $na))))
    (struct.set $StrBuf $used (local.get $buf) (local.get $n))
    (struct.new $LuaBufStr (ref.null $LuaArr) (i32.const 0) (local.get $n) (local.get $buf)))
  ;; A buffer holding the unread node $a followed by $b; the result is $n long.
  (func $buf_start (param $a (ref $LuaRope)) (param $b anyref) (param $sb (ref null $LuaArr))
                   (param $n i32) (result anyref)
    (local $na i32) (local $arr (ref $LuaArr))
    (local.set $na (struct.get $LuaLazy $len (local.get $a)))
    (local.set $arr (array.new $LuaArr (i32.const 0) (call $buf_cap (local.get $n))))
    (drop (call $lazy_write (local.get $arr) (local.get $na) (local.get $a)))
    (drop (call $concat_put (local.get $arr) (local.get $na) (local.get $b) (local.get $sb)
                            (i32.sub (local.get $n) (local.get $na))))
    (struct.new $LuaBufStr (ref.null $LuaArr) (i32.const 0) (local.get $n)
      (struct.new $StrBuf (local.get $arr) (local.get $n))))
  (func $concat_str (param $v anyref) (param $bytes (ref null $LuaArr)) (result (ref $LuaString))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return (ref.cast (ref $LuaString) (local.get $v)))))
    (if (ref.is_null (local.get $bytes))
      (then (return (call $str_of_bytes (call $int_to_bytes (call $as_int (local.get $v))) (i32.const 3)))))
    (struct.new $LuaString (local.get $bytes) (i32.const 0)))

  (func $lua_concat (param $a anyref) (param $b anyref) (result anyref)
    (local $sa (ref null $LuaArr)) (local $sb (ref null $LuaArr)) (local $out (ref $LuaArr))
    (local $na i32) (local $nb i32)
    (if (i32.eqz (i32.and (call $is_concatable (local.get $a))
                          (call $is_concatable (local.get $b))))
      (then (return (call $arith_mm (local.get $a) (local.get $b)
                      (ref.as_non_null (global.get $g_mkey_concat))))))
    (call $concat_piece (local.get $a)) (local.set $na) (local.set $sa)
    (call $concat_piece (local.get $b)) (local.set $nb) (local.set $sb)
    ;; at least the minimum: a lazy string (which raises "too large")
    (if (i32.ge_u (i32.add (local.get $na) (local.get $nb)) (i32.const 128))
      (then (return (call $concat_lazy (local.get $a) (local.get $sa) (local.get $b) (local.get $sb)
        (i64.add (i64.extend_i32_u (local.get $na)) (i64.extend_i32_u (local.get $nb)))))))
    (local.set $out (array.new $LuaArr (i32.const 0)
                       (i32.add (local.get $na) (local.get $nb))))
    (drop (call $concat_put (local.get $out)
      (call $concat_put (local.get $out) (i32.const 0) (local.get $a) (local.get $sa) (local.get $na))
      (local.get $b) (local.get $sb) (local.get $nb)))
    (call $str_of_bytes (local.get $out) (i32.const 0)))

  ;; `a .. b .. c` / `a .. b .. c .. d` in one allocation (under the 128-byte
  ;; minimum for a lazy string): codegen flattens a right-nested chain, whose
  ;; operands are already evaluated left to right.
  ;; When one isn't a string or number the chain is concatenated pairwise from
  ;; the right, as reference Lua does, so __concat sees the same calls.
  (func $lua_concat3 (param $a anyref) (param $b anyref) (param $c anyref) (result anyref)
    (local $sa (ref null $LuaArr)) (local $sb (ref null $LuaArr)) (local $sc (ref null $LuaArr))
    (local $na i32) (local $nb i32) (local $nc i32) (local $out (ref $LuaArr)) (local $n i64)
    (if (i32.eqz (i32.and (call $is_concatable (local.get $a))
                          (i32.and (call $is_concatable (local.get $b)) (call $is_concatable (local.get $c)))))
      (then (return (call $lua_concat (local.get $a) (call $lua_concat (local.get $b) (local.get $c))))))
    (call $concat_piece (local.get $a)) (local.set $na) (local.set $sa)
    (call $concat_piece (local.get $b)) (local.set $nb) (local.set $sb)
    (call $concat_piece (local.get $c)) (local.set $nc) (local.set $sc)
    (local.set $n (i64.add (i64.extend_i32_u (local.get $na))
                  (i64.add (i64.extend_i32_u (local.get $nb)) (i64.extend_i32_u (local.get $nc)))))
    ;; at least the minimum: lazy strings, pairwise from the right — so a long
    ;; first operand (`acc .. x .. y`) gets one node over the short rest
    (if (i64.ge_u (local.get $n) (i64.const 128))
      (then (return (call $lua_concat (local.get $a) (call $lua_concat (local.get $b) (local.get $c))))))
    (local.set $out (array.new $LuaArr (i32.const 0) (i32.wrap_i64 (local.get $n))))
    (drop (call $concat_put (local.get $out)
      (call $concat_put (local.get $out)
        (call $concat_put (local.get $out) (i32.const 0) (local.get $a) (local.get $sa) (local.get $na))
        (local.get $b) (local.get $sb) (local.get $nb))
      (local.get $c) (local.get $sc) (local.get $nc)))
    (call $str_of_bytes (local.get $out) (i32.const 0)))
  (func $lua_concat4 (param $a anyref) (param $b anyref) (param $c anyref) (param $d anyref) (result anyref)
    (local $sa (ref null $LuaArr)) (local $sb (ref null $LuaArr)) (local $sc (ref null $LuaArr))
    (local $sd (ref null $LuaArr)) (local $na i32) (local $nb i32) (local $nc i32) (local $nd i32)
    (local $out (ref $LuaArr)) (local $n i64)
    (if (i32.eqz (i32.and (i32.and (call $is_concatable (local.get $a)) (call $is_concatable (local.get $b)))
                          (i32.and (call $is_concatable (local.get $c)) (call $is_concatable (local.get $d)))))
      (then (return (call $lua_concat (local.get $a)
        (call $lua_concat (local.get $b) (call $lua_concat (local.get $c) (local.get $d)))))))
    (call $concat_piece (local.get $a)) (local.set $na) (local.set $sa)
    (call $concat_piece (local.get $b)) (local.set $nb) (local.set $sb)
    (call $concat_piece (local.get $c)) (local.set $nc) (local.set $sc)
    (call $concat_piece (local.get $d)) (local.set $nd) (local.set $sd)
    (local.set $n (i64.add (i64.add (i64.extend_i32_u (local.get $na)) (i64.extend_i32_u (local.get $nb)))
                           (i64.add (i64.extend_i32_u (local.get $nc)) (i64.extend_i32_u (local.get $nd)))))
    (if (i64.ge_u (local.get $n) (i64.const 128))   ;; lazy, as in $lua_concat3
      (then (return (call $lua_concat (local.get $a)
        (call $lua_concat (local.get $b) (call $lua_concat (local.get $c) (local.get $d)))))))
    (local.set $out (array.new $LuaArr (i32.const 0) (i32.wrap_i64 (local.get $n))))
    (drop (call $concat_put (local.get $out)
      (call $concat_put (local.get $out)
        (call $concat_put (local.get $out)
          (call $concat_put (local.get $out) (i32.const 0) (local.get $a) (local.get $sa) (local.get $na))
          (local.get $b) (local.get $sb) (local.get $nb))
        (local.get $c) (local.get $sc) (local.get $nc))
      (local.get $d) (local.get $sd) (local.get $nd)))
    (call $str_of_bytes (local.get $out) (i32.const 0)))

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
