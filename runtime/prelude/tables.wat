;; Tables: shapes, the hash part (hashing, probing, insertion, compaction),
;; the array part (holes, append, trim, demotion), raw get/set and length.

  ;; Monotonic identity counter for tables. WasmGC exposes no pointer or
  ;; identity hash, so each $LuaTable is stamped with a unique id at creation
  ;; ($tab_new) and $lua_hash mixes it — without this, every table key hashes
  ;; to 0 and a table-keyed map degrades to O(n^2).
  (global $g_next_table_id (mut i32) (i32.const 1))
  ;; Max length of a table's array part (16M entries). Beyond this, integer
  ;; keys fall into the hash part, so a pathological sequence can't grow a single
  ;; array past the engine's array-size limit (an uncatchable trap).
  (global $arr_max i32 (i32.const 16777216))

  ;; --- tables (open-addressing hash index over dense key/value arrays) ---
  ;; A value slot as a Lua value: the marker resolves to the parallel f64.
  (func $tval (param $v anyref) (param $fa (ref null $FArr)) (param $i i32) (result anyref)
    (if (ref.test (ref $FMark) (local.get $v))
      (then (return (call $make_float (array.get $FArr (ref.as_non_null (local.get $fa)) (local.get $i))))))
    (local.get $v))
  (func $farr_grow (param $old (ref $FArr)) (param $new_cap i32) (param $n i32) (result (ref $FArr))
    (local $new (ref $FArr))
    (local.set $new (array.new $FArr (f64.const 0) (local.get $new_cap)))
    (array.copy $FArr $FArr (local.get $new) (i32.const 0) (local.get $old) (i32.const 0) (local.get $n))
    (local.get $new))
  (func $fvals_ensure (param $t (ref $LuaTable)) (result (ref $FArr))
    (local $fa (ref null $FArr))
    (local.set $fa (struct.get $LuaTable $fvals (local.get $t)))
    (if (ref.is_null (local.get $fa))
      (then
        (local.set $fa (array.new $FArr (f64.const 0)
          (array.len (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))))))
        (struct.set $LuaTable $fvals (local.get $t) (local.get $fa))))
    (ref.as_non_null (local.get $fa)))
  (func $farr_ensure (param $t (ref $LuaTable)) (result (ref $FArr))
    (local $fa (ref null $FArr)) (local $len i32)
    (local.set $len (array.len (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))))
    (local.set $fa (struct.get $LuaTable $farr (local.get $t)))
    (if (ref.is_null (local.get $fa))
      (then
        (local.set $fa (array.new $FArr (f64.const 0) (local.get $len)))
        (struct.set $LuaTable $farr (local.get $t) (local.get $fa)))
      (else (if (i32.lt_s (array.len (ref.as_non_null (local.get $fa))) (local.get $len))
        (then
          (local.set $fa (call $farr_grow (ref.as_non_null (local.get $fa)) (local.get $len)
                                          (array.len (ref.as_non_null (local.get $fa)))))
          (struct.set $LuaTable $farr (local.get $t) (local.get $fa))))))
    (ref.as_non_null (local.get $fa)))

  ;; Every table starts on the shared empty shape. Its transition cache is
  ;; larger than a child's: every table built up from `{}` starts here.
  (global $g_root_shape (ref $Shape)
    (struct.new $Shape (array.new_fixed $TArr 0) (array.new $IArr (i32.const 0) (i32.const 8))
      (i32.const 7) (i32.const 0) (i32.const 0)
      (array.new $TArr (ref.null any) (i32.const 64))
      (array.new $ShapeArr (ref.null $Shape) (i32.const 64))))
  ;; A table whose hash part reaches this many keys gets a private shape:
  ;; it is a dictionary, not a record.
  (global $shape_share_max i32 (i32.const 32))

  (func $tab_new (result (ref $LuaTable))
    (local $id i32)
    (local.set $id (global.get $g_next_table_id))
    (global.set $g_next_table_id (i32.add (local.get $id) (i32.const 1)))
    (struct.new $LuaTable
      (global.get $g_root_shape) (ref.null $TArr) (i32.const 0)
      (ref.null $LuaTable)
      (local.get $id)
      (ref.null $TArr) (i32.const 0)   ;; $arr, $alen
      (ref.null $FArr) (ref.null $FArr)))

  ;; `{v1, ..., vn}`: a constructor's positional values, evaluated into $a,
  ;; become the array part at once. As the stores one by one would have it,
  ;; the array part is the values before the first nil; any after it are
  ;; moved out through $tab_set_ik (to the hash part).
  (func $tab_new_arr (param $a (ref $TArr)) (result anyref)
    (local $t (ref $LuaTable)) (local $n i32) (local $i i32) (local $j i32) (local $v anyref)
    (local.set $t (call $tab_new))
    (local.set $n (array.len (local.get $a)))
    (block $end (loop $prefix
      (br_if $end (i32.ge_u (local.get $i) (local.get $n)))
      (br_if $end (ref.is_null (array.get $TArr (local.get $a) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $prefix)))
    (struct.set $LuaTable $arr (local.get $t) (local.get $a))
    (struct.set $LuaTable $alen (local.get $t) (local.get $i))
    (if (i32.lt_u (local.get $i) (local.get $n))
      (then (return_call $tab_new_arr_rest (local.get $t) (local.get $a) (local.get $i))))
    (local.get $t))
  ;; The values after the first nil at $from.
  (func $tab_new_arr_rest (param $t (ref $LuaTable)) (param $a (ref $TArr)) (param $from i32) (result anyref)
    (local $j i32) (local $v anyref)
    (local.set $j (i32.add (local.get $from) (i32.const 1)))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $j) (array.len (local.get $a))))
      (local.set $v (array.get $TArr (local.get $a) (local.get $j)))
      (array.set $TArr (local.get $a) (local.get $j) (ref.null any))
      (if (i32.eqz (ref.is_null (local.get $v)))
        (then (call $tab_set_ik (local.get $t) (i64.extend_i32_u (i32.add (local.get $j) (i32.const 1))) (local.get $v))))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br $lp)))
    (local.get $t))

  ;; Make room for `need` values in the hash part's value array (geometric,
  ;; initial 4), growing the parallel float storage with it.
  (func $vals_reserve (param $t (ref $LuaTable)) (param $need i32)
    (local $v (ref null $TArr)) (local $len i32) (local $cap i32) (local $nv (ref $TArr))
    (local.set $v (struct.get $LuaTable $vals (local.get $t)))
    (local.set $len (if (result i32) (ref.is_null (local.get $v))
      (then (i32.const 0)) (else (array.len (ref.as_non_null (local.get $v))))))
    (if (i32.ge_s (local.get $len) (local.get $need)) (then (return)))
    (local.set $cap (if (result i32) (i32.eqz (local.get $len))
      (then (i32.const 4)) (else (i32.shl (local.get $len) (i32.const 1)))))
    (if (i32.gt_s (local.get $need) (local.get $cap)) (then (local.set $cap (local.get $need))))
    ;; Trip a Lua-level "table overflow" before wasm's array.new traps.
    ;; 2^24 = 16M slots keeps each (anyref) array at ~128MB on a 64-bit
    ;; host, well under V8's per-array allocation limit. Pcall can then
    ;; catch the error cleanly (heavy.lua relies on this for its
    ;; "expected error" smoke).
    (if (i32.gt_u (local.get $cap) (i32.const 16777216))
      (then (call $throw_lit (i32.const 341) (i32.const 14))))   ;; "table overflow"
    (local.set $nv (array.new $TArr (ref.null any) (local.get $cap)))
    (if (i32.gt_s (local.get $len) (i32.const 0))
      (then (array.copy $TArr $TArr (local.get $nv) (i32.const 0)
              (ref.as_non_null (local.get $v)) (i32.const 0) (local.get $len))))
    (struct.set $LuaTable $vals (local.get $t) (local.get $nv))
    (if (i32.eqz (ref.is_null (struct.get $LuaTable $fvals (local.get $t))))
      (then (struct.set $LuaTable $fvals (local.get $t)
        (call $farr_grow (ref.as_non_null (struct.get $LuaTable $fvals (local.get $t)))
                         (local.get $cap) (local.get $len))))))

  ;; A fresh index over keys[0..n): power-of-two sized >= 2*(n+1), minimum 8,
  ;; no tombstones. Returns it with its mask.
  (func $shape_index (param $keys (ref $TArr)) (param $n i32) (result (ref $IArr) i32)
    (local $cap i32) (local $mask i32) (local $idx (ref $IArr)) (local $i i32) (local $h i32)
    (local.set $cap (i32.const 8))
    (block $sized (loop $grow
      (br_if $sized (i32.ge_u (local.get $cap) (i32.shl (i32.add (local.get $n) (i32.const 1)) (i32.const 1))))
      (local.set $cap (i32.shl (local.get $cap) (i32.const 1)))
      (br $grow)))
    (local.set $mask (i32.sub (local.get $cap) (i32.const 1)))
    (local.set $idx (array.new $IArr (i32.const 0) (local.get $cap)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $h (i32.and (local.get $mask)
        (call $lua_hash (array.get $TArr (local.get $keys) (local.get $i)))))
      (block $placed (loop $probe
        (if (i32.eqz (array.get $IArr (local.get $idx) (local.get $h)))
          (then
            (array.set $IArr (local.get $idx) (local.get $h) (i32.add (local.get $i) (i32.const 1)))
            (br $placed)))
        (local.set $h (i32.and (local.get $mask) (i32.add (local.get $h) (i32.const 1))))
        (br $probe)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $idx) (local.get $mask))

  ;; The shape `parent` plus string key $k (hash $full) at position parent.n:
  ;; from the parent's transition cache when this key object was added before,
  ;; else built and cached (evicting whatever shared its slot). Shapes are
  ;; immutable once built, so any number of tables can share one.
  (func $shape_child (param $parent (ref $Shape)) (param $k (ref $LuaString)) (param $full i32)
                     (result (ref $Shape))
    (local $tk (ref null $TArr)) (local $tc (ref null $ShapeArr)) (local $slot i32)
    (local $n i32) (local $keys (ref $TArr)) (local $idx (ref $IArr)) (local $mask i32)
    (local $child (ref $Shape))
    (local.set $tk (struct.get $Shape $tkeys (local.get $parent)))
    (if (i32.eqz (ref.is_null (local.get $tk)))
      (then
        (local.set $slot (i32.and (local.get $full)
          (i32.sub (array.len (ref.as_non_null (local.get $tk))) (i32.const 1))))
        (if (ref.eq (ref.cast (ref null eq) (array.get $TArr (ref.as_non_null (local.get $tk)) (local.get $slot)))
                    (local.get $k))
          (then (return (ref.as_non_null (array.get $ShapeArr
            (ref.as_non_null (struct.get $Shape $tkids (local.get $parent))) (local.get $slot))))))))
    (local.set $n (struct.get $Shape $n (local.get $parent)))
    (local.set $keys (array.new $TArr (ref.null any) (i32.add (local.get $n) (i32.const 1))))
    (array.copy $TArr $TArr (local.get $keys) (i32.const 0)
      (struct.get $Shape $keys (local.get $parent)) (i32.const 0) (local.get $n))
    (array.set $TArr (local.get $keys) (local.get $n) (local.get $k))
    (call $shape_index (local.get $keys) (i32.add (local.get $n) (i32.const 1)))
    (local.set $mask)
    (local.set $idx)
    (local.set $child (struct.new $Shape (local.get $keys) (local.get $idx) (local.get $mask)
      (i32.add (local.get $n) (i32.const 1)) (i32.add (local.get $n) (i32.const 1))
      (ref.null $TArr) (ref.null $ShapeArr)))
    (if (ref.is_null (local.get $tk))
      (then
        (local.set $tk (array.new $TArr (ref.null any) (i32.const 8)))
        (struct.set $Shape $tkeys (local.get $parent) (local.get $tk))
        (struct.set $Shape $tkids (local.get $parent) (array.new $ShapeArr (ref.null $Shape) (i32.const 8)))
        (local.set $slot (i32.and (local.get $full) (i32.const 7)))))
    (array.set $TArr (ref.as_non_null (local.get $tk)) (local.get $slot) (local.get $k))
    (array.set $ShapeArr (ref.as_non_null (struct.get $Shape $tkids (local.get $parent)))
      (local.get $slot) (local.get $child))
    (local.get $child))

  ;; Give $t a private copy of its shape, which its inserts then mutate in
  ;; place (a dictionary: non-string keys, or past $shape_share_max keys).
  (func $tab_own (param $t (ref $LuaTable))
    (local $sh (ref $Shape)) (local $n i32) (local $keys (ref $TArr)) (local $idx (ref $IArr))
    (if (struct.get $LuaTable $own (local.get $t)) (then (return)))
    (local.set $sh (struct.get $LuaTable $shape (local.get $t)))
    (local.set $n (struct.get $Shape $n (local.get $sh)))
    (local.set $keys (array.new $TArr (ref.null any)
      (if (result i32) (i32.gt_s (local.get $n) (i32.const 4)) (then (local.get $n)) (else (i32.const 4)))))
    (array.copy $TArr $TArr (local.get $keys) (i32.const 0)
      (struct.get $Shape $keys (local.get $sh)) (i32.const 0) (local.get $n))
    (local.set $idx (array.new $IArr (i32.const 0) (array.len (struct.get $Shape $idx (local.get $sh)))))
    (array.copy $IArr $IArr (local.get $idx) (i32.const 0)
      (struct.get $Shape $idx (local.get $sh)) (i32.const 0) (array.len (local.get $idx)))
    (struct.set $LuaTable $shape (local.get $t)
      (struct.new $Shape (local.get $keys) (local.get $idx) (struct.get $Shape $mask (local.get $sh))
        (local.get $n) (struct.get $Shape $used (local.get $sh)) (ref.null $TArr) (ref.null $ShapeArr)))
    (struct.set $LuaTable $own (local.get $t) (i32.const 1)))

  ;; The shape a table reaches by adding the string keys $keys in order from
  ;; empty — the same shape incremental construction reaches. Built once per
  ;; constructor site (codegen caches it in a module global).
  (func $shape_for_keys (param $keys (ref $TArr)) (result (ref $Shape))
    (local $sh (ref $Shape)) (local $i i32) (local $k (ref $LuaString))
    (local.set $sh (global.get $g_root_shape))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (array.len (local.get $keys))))
      (local.set $k (ref.cast (ref $LuaString) (array.get $TArr (local.get $keys) (local.get $i))))
      (local.set $sh (call $shape_child (local.get $sh) (local.get $k) (call $str_hash (local.get $k))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $sh))

  ;; A constructor's table: its final shape up front, values filled in by
  ;; position ($tab_put_pos / $tab_put_pos_f) in field order.
  (func $tab_new_shaped (param $sh (ref $Shape)) (result (ref $LuaTable))
    (local $id i32)
    (local.set $id (global.get $g_next_table_id))
    (global.set $g_next_table_id (i32.add (local.get $id) (i32.const 1)))
    (struct.new $LuaTable
      (local.get $sh) (array.new $TArr (ref.null any) (struct.get $Shape $n (local.get $sh))) (i32.const 0)
      (ref.null $LuaTable)
      (local.get $id)
      (ref.null $TArr) (i32.const 0)
      (ref.null $FArr) (ref.null $FArr)))
  (func $tab_put_pos (param $t (ref $LuaTable)) (param $pos i32) (param $v anyref)
    (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $pos) (local.get $v)))
  (func $tab_put_pos_f (param $t (ref $LuaTable)) (param $pos i32) (param $f f64)
    (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $pos)
      (global.get $g_fmark))
    (array.set $FArr (call $fvals_ensure (local.get $t)) (local.get $pos) (local.get $f)))

  ;; Reserve room for `cap` hash entries (table.create's record hint): a
  ;; private shape with that much key capacity, and the value array.
  (func $tab_reserve_hash (param $t (ref $LuaTable)) (param $cap i32)
    (local $sh (ref $Shape)) (local $nk (ref $TArr))
    (call $tab_own (local.get $t))
    (local.set $sh (struct.get $LuaTable $shape (local.get $t)))
    (if (i32.gt_s (local.get $cap) (array.len (struct.get $Shape $keys (local.get $sh))))
      (then
        (if (i32.gt_u (local.get $cap) (i32.const 16777216))
          (then (call $throw_lit (i32.const 341) (i32.const 14))))   ;; "table overflow"
        (local.set $nk (array.new $TArr (ref.null any) (local.get $cap)))
        (array.copy $TArr $TArr (local.get $nk) (i32.const 0)
          (struct.get $Shape $keys (local.get $sh)) (i32.const 0) (struct.get $Shape $n (local.get $sh)))
        (struct.set $Shape $keys (local.get $sh) (local.get $nk))))
    (call $vals_reserve (local.get $t) (local.get $cap)))


  ;; Cached FNV-1a hash of a string (see the $hash field note on $LuaString):
  ;; computed once by $str_hash_compute. Codegen precomputes the same function
  ;; for constant strings (kstr_hash in src/codegen/strings.c) — keep the two in sync.
  (func $str_hash (param $s (ref $LuaString)) (result i32)
    (local $h i32)
    (local.set $h (struct.get $LuaString $hash (local.get $s)))
    (if (local.get $h) (then (return (local.get $h))))
    (return_call $str_hash_compute (local.get $s)))
  (func $str_hash_compute (param $s (ref $LuaString)) (result i32)
    (local $h i32) (local $bytes (ref $LuaArr)) (local $i i32) (local $n i32)
    (local.set $bytes (struct.get $LuaString $bytes (local.get $s)))
    (local.set $h (i32.const -2128831035)) ;; FNV offset basis
    (local.set $n (array.len (local.get $bytes)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $h (i32.mul
        (i32.xor (local.get $h) (array.get_u $LuaArr (local.get $bytes) (local.get $i)))
        (i32.const 16777619)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (if (i32.eqz (local.get $h)) (then (local.set $h (i32.const 1))))
    (struct.set $LuaString $hash (local.get $s) (local.get $h))
    (local.get $h))


  ;; Hash any Lua value to an i32. The only requirement for correctness
  ;; is that values that compare equal (via $lua_eq_raw) hash equally —
  ;; specifically Lua's int↔float equivalence at integer values. The usual
  ;; keys come first: a string (its cached hash) and a small integer, hashed
  ;; as the low ^ high words of its i64 like every integer; the rest is
  ;; $lua_hash_other.
  (func $lua_hash (param $v anyref) (result i32)
    (local $i i32)
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return_call $str_hash (ref.cast (ref $LuaString) (local.get $v)))))
    (if (ref.test (ref i31) (local.get $v))
      (then
        (local.set $i (i31.get_s (ref.cast (ref i31) (local.get $v))))
        (return (i32.xor (local.get $i) (i32.shr_s (local.get $i) (i32.const 31))))))
    (if (ref.test (ref $LuaTable) (local.get $v))
      (then (return (i32.mul (struct.get $LuaTable $id (ref.cast (ref $LuaTable) (local.get $v)))
                             (i32.const -1640531527)))))   ;; as in $lua_hash_other
    (return_call $lua_hash_other (local.get $v)))
  (func $lua_hash_other (param $v anyref) (result i32)
    (local $h i32) (local $bytes (ref null $LuaArr)) (local $i i32) (local $n i32)
    (local $f f64)
    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
    (if (call $is_int (local.get $v))
      (then (return (i32.xor
        (i32.wrap_i64 (call $as_int (local.get $v)))
        (i32.wrap_i64 (i64.shr_u (call $as_int (local.get $v)) (i64.const 32)))))))
    (if (call $is_float (local.get $v))
      (then
        (local.set $f (call $as_float (local.get $v)))
        ;; integer-valued floats must hash like the equivalent int.
        (if (f64.eq (local.get $f) (f64.trunc (local.get $f)))
          (then
            (if (i32.and (f64.ge (local.get $f) (f64.const -9.2233720368547758e+18))
                         (f64.lt (local.get $f) (f64.const  9.2233720368547758e+18)))
              (then (return (i32.xor
                (i32.wrap_i64 (i64.trunc_f64_s (local.get $f)))
                (i32.wrap_i64 (i64.shr_u (i64.trunc_f64_s (local.get $f)) (i64.const 32))))))))
          (else))
        (return (i32.xor
          (i32.wrap_i64 (i64.reinterpret_f64 (local.get $f)))
          (i32.wrap_i64 (i64.shr_u (i64.reinterpret_f64 (local.get $f)) (i64.const 32)))))))
    (if (ref.test (ref $LuaBool) (local.get $v))
      (then (return (struct.get $LuaBool $b (ref.cast (ref $LuaBool) (local.get $v))))))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then (return (call $str_hash (ref.cast (ref $LuaString) (local.get $v))))))
    ;; Tables carry a unique $id; mix it (Knuth multiplicative hash) so
    ;; sequentially-created tables spread across the index instead of
    ;; clustering. Closures have no id field, so they still hash to 0 and
    ;; resolve via linear probe (function-as-key is rare).
    (if (ref.test (ref $LuaTable) (local.get $v))
      (then (return (i32.mul
        (struct.get $LuaTable $id (ref.cast (ref $LuaTable) (local.get $v)))
        (i32.const -1640531527)))))   ;; 0x9E3779B9
    (i32.const 0))

  ;; Rebuild the hash index, reclaiming lazily-deleted entries. Walks
  ;; keys[0..n-1] keeping only live entries (vals[i] != nil), compacts them
  ;; to the front of keys/vals (in place — positions only ever move left),
  ;; rebuilds the index over them, and resets $n to the live count. The
  ;; index is sized from the *live* count (next pow2 ≥ 2*(live+1), min 8),
  ;; so it grows on a normal insert burst yet shrinks back when the rebuild
  ;; reclaims dead entries — keeping insert/delete churn O(1) in space.
  (func $tab_index_rebuild (param $t (ref $LuaTable))
    (local $sh (ref $Shape))
    (local $idx (ref $IArr)) (local $keys (ref $TArr)) (local $vals (ref null $TArr))
    (local $i i32) (local $j i32) (local $n i32) (local $h i32) (local $mask i32)
    (local $cap i32) (local $live i32) (local $kk anyref)
    ;; Only a private (owned) shape is rebuilt; compaction moves keys within
    ;; it and values within this table.
    (local.set $sh (struct.get $LuaTable $shape (local.get $t)))
    (local.set $keys (struct.get $Shape $keys (local.get $sh)))
    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
    (local.set $n (struct.get $Shape $n (local.get $sh)))
    ;; First pass: count the live entries so the index can be sized to them.
    (if (i32.eqz (ref.is_null (local.get $vals)))
      (then
        (block $cnt_done (loop $cnt
          (br_if $cnt_done (i32.ge_s (local.get $i) (local.get $n)))
          (if (i32.eqz (ref.is_null (array.get $TArr
                (ref.as_non_null (local.get $vals)) (local.get $i))))
            (then (local.set $live (i32.add (local.get $live) (i32.const 1)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $cnt)))))
    ;; cap = smallest power of two ≥ 2*(live+1), at least 8.
    (local.set $cap (i32.const 8))
    (block $sized (loop $grow
      (br_if $sized (i32.ge_u (local.get $cap)
        (i32.shl (i32.add (local.get $live) (i32.const 1)) (i32.const 1))))
      (local.set $cap (i32.shl (local.get $cap) (i32.const 1)))
      (br $grow)))
    (local.set $mask (i32.sub (local.get $cap) (i32.const 1)))
    (local.set $idx (array.new $IArr (i32.const 0) (local.get $cap)))
    (local.set $i (i32.const 0))
    (if (i32.eqz (ref.is_null (local.get $vals)))
      (then
        (block $kdone (loop $klp
          (br_if $kdone (i32.ge_s (local.get $i) (local.get $n)))
          ;; Skip dead entries (deleted: value cleared to nil).
          (if (i32.eqz (ref.is_null (array.get $TArr
                (ref.as_non_null (local.get $vals)) (local.get $i))))
            (then
              ;; Compact entry $i down to $j (no-op when $i == $j).
              (if (i32.ne (local.get $i) (local.get $j))
                (then
                  (array.set $TArr (local.get $keys) (local.get $j)
                    (array.get $TArr (local.get $keys) (local.get $i)))
                  (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $j)
                    (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $i)))
                  (if (i32.eqz (ref.is_null (struct.get $LuaTable $fvals (local.get $t))))
                    (then (array.set $FArr (ref.as_non_null (struct.get $LuaTable $fvals (local.get $t))) (local.get $j)
                      (array.get $FArr (ref.as_non_null (struct.get $LuaTable $fvals (local.get $t))) (local.get $i)))))))
              (local.set $kk (array.get $TArr (local.get $keys) (local.get $j)))
              (local.set $h (i32.and (local.get $mask) (call $lua_hash (local.get $kk))))
              (block $place (loop $probe
                (if (i32.eqz (array.get $IArr (local.get $idx) (local.get $h)))
                  (then
                    (array.set $IArr (local.get $idx) (local.get $h)
                      (i32.add (local.get $j) (i32.const 1)))
                    (br $place)))
                (local.set $h (i32.and (local.get $mask)
                  (i32.add (local.get $h) (i32.const 1))))
                (br $probe)))
              (local.set $j (i32.add (local.get $j) (i32.const 1)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $klp)))
        ;; Null out the reclaimed tail so the dropped entries can be GC'd.
        (local.set $i (local.get $j))
        (block $cdone (loop $clp
          (br_if $cdone (i32.ge_s (local.get $i) (local.get $n)))
          (array.set $TArr (local.get $keys) (local.get $i) (ref.null any))
          (array.set $TArr (ref.as_non_null (local.get $vals)) (local.get $i) (ref.null any))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $clp)))))
    ;; Compaction moved keys, so the table gets a new shape object: a cached
    ;; (shape, position) for the old one must not match it any more. A fresh
    ;; index has no tombstones: occupied slots == live entries.
    (struct.set $LuaTable $shape (local.get $t)
      (struct.new $Shape (local.get $keys) (local.get $idx) (local.get $mask)
        (local.get $j) (local.get $j) (ref.null $TArr) (ref.null $ShapeArr))))


  ;; Probe the hash index for a key. Returns position in keys[] (>=0)
  ;; on hit, -1 on miss. Caller must ensure $idx is non-null (i.e. n>0
  ;; — empty tables short-circuit in tab_find).
  (func $tab_index_lookup (param $t (ref $LuaTable)) (param $k anyref) (result i32)
    (call $tab_index_lookup_h (local.get $t) (local.get $k) (call $lua_hash (local.get $k))))

  ;; Hash-part probe for a string key whose full hash is already known (the
  ;; codegen constant-key entry points read it straight off the hoisted
  ;; global). Same protocol as $tab_index_lookup_h minus the key-type
  ;; dispatch: identity, then cached-hash gate, then bytes. A null index means
  ;; the hash part has never been populated.
  (func $tab_find_str (param $t (ref $LuaTable)) (param $k (ref $LuaString)) (param $full i32) (result i32)
    (local $sh (ref $Shape)) (local $slot i32)
    ;; Settle the common cases on the key's home slot: empty means absent;
    ;; holding this very key object means found (constant keys are hoisted,
    ;; so a store and a load usually pass the same object). Anything else
    ;; walks the probe chain.
    (local.set $sh (struct.get $LuaTable $shape (local.get $t)))
    (local.set $slot (array.get $IArr (struct.get $Shape $idx (local.get $sh))
      (i32.and (struct.get $Shape $mask (local.get $sh)) (local.get $full))))
    (if (i32.eqz (local.get $slot)) (then (return (i32.const -1))))
    (if (i32.gt_s (local.get $slot) (i32.const 0))
      (then (if (ref.eq (ref.cast (ref null eq) (array.get $TArr (struct.get $Shape $keys (local.get $sh))
                                                          (i32.sub (local.get $slot) (i32.const 1))))
                        (local.get $k))
        (then (return (i32.sub (local.get $slot) (i32.const 1)))))))
    (return_call $tab_find_str_probe (local.get $t) (local.get $k) (local.get $full)))
  (func $tab_find_str_probe (param $t (ref $LuaTable)) (param $k (ref $LuaString)) (param $full i32) (result i32)
    (local $idx (ref null $IArr)) (local $keys (ref $TArr)) (local $sh (ref $Shape))
    (local $mask i32) (local $h i32) (local $slot i32) (local $pos i32) (local $sk anyref)
    (local.set $sh (struct.get $LuaTable $shape (local.get $t)))
    (local.set $idx (struct.get $Shape $idx (local.get $sh)))
    (local.set $keys (struct.get $Shape $keys (local.get $sh)))
    (local.set $mask (struct.get $Shape $mask (local.get $sh)))
    (local.set $h (i32.and (local.get $mask) (local.get $full)))
    (loop $probe
      (local.set $slot (array.get $IArr (ref.as_non_null (local.get $idx)) (local.get $h)))
      (if (i32.eqz (local.get $slot)) (then (return (i32.const -1))))
      (if (i32.gt_s (local.get $slot) (i32.const 0))
        (then
          (local.set $pos (i32.sub (local.get $slot) (i32.const 1)))
          (local.set $sk (array.get $TArr (local.get $keys) (local.get $pos)))
          (if (ref.eq (ref.cast (ref null eq) (local.get $sk)) (local.get $k))
            (then (return (local.get $pos))))
          (if (ref.test (ref $LuaString) (local.get $sk))
            (then (if (i32.eq (struct.get $LuaString $hash (ref.cast (ref $LuaString) (local.get $sk)))
                              (local.get $full))
              (then (if (call $str_eq (local.get $sk) (local.get $k))
                (then (return (local.get $pos))))))))))
      (local.set $h (i32.and (local.get $mask) (i32.add (local.get $h) (i32.const 1))))
      (br $probe))
    (i32.const -1))

  (func $tab_index_lookup_h (param $t (ref $LuaTable)) (param $k anyref) (param $full i32) (result i32)
    (local $sh (ref $Shape)) (local $slot i32)
    ;; As $tab_find_str: an empty home slot or an identical key there settles
    ;; it (identity covers small integers, tables and hoisted strings).
    (local.set $sh (struct.get $LuaTable $shape (local.get $t)))
    (local.set $slot (array.get $IArr (struct.get $Shape $idx (local.get $sh))
      (i32.and (struct.get $Shape $mask (local.get $sh)) (local.get $full))))
    (if (i32.eqz (local.get $slot)) (then (return (i32.const -1))))
    (if (i32.gt_s (local.get $slot) (i32.const 0))
      (then (if (ref.eq (ref.cast (ref null eq) (array.get $TArr (struct.get $Shape $keys (local.get $sh))
                                                          (i32.sub (local.get $slot) (i32.const 1))))
                        (ref.cast (ref null eq) (local.get $k)))
        (then (return (i32.sub (local.get $slot) (i32.const 1)))))))
    (return_call $tab_index_lookup_probe (local.get $t) (local.get $k) (local.get $full)))
  (func $tab_index_lookup_probe (param $t (ref $LuaTable)) (param $k anyref) (param $full i32) (result i32)
    (local $idx (ref $IArr)) (local $keys (ref $TArr))
    (local $mask i32) (local $h i32) (local $slot i32) (local $pos i32)
    (local $is_str i32) (local $by_value i32) (local $sk anyref)
    (local $sh (ref $Shape))
    (local.set $sh (struct.get $LuaTable $shape (local.get $t)))
    (local.set $idx (struct.get $Shape $idx (local.get $sh)))
    (local.set $keys (struct.get $Shape $keys (local.get $sh)))
    (local.set $mask (struct.get $Shape $mask (local.get $sh)))
    (local.set $h (i32.and (local.get $mask) (local.get $full)))
    (local.set $is_str (ref.test (ref $LuaString) (local.get $k)))
    ;; Stored integer keys are normalized (an integral float to an integer, a
    ;; small one to an i31), so only a wide integer or a float can equal a key
    ;; that isn't the same object; anything else matches by identity alone.
    (local.set $by_value (i32.or (ref.test (ref $LuaInt) (local.get $k)) (ref.test (ref $LuaFloat) (local.get $k))))
    (loop $probe
      (local.set $slot (array.get $IArr (local.get $idx) (local.get $h)))
      ;; 0 = empty -> key absent; <0 = tombstone -> keep probing; >0 = live.
      (if (i32.eqz (local.get $slot)) (then (return (i32.const -1))))
      (if (i32.gt_s (local.get $slot) (i32.const 0))
        (then
          (local.set $pos (i32.sub (local.get $slot) (i32.const 1)))
          (local.set $sk (array.get $TArr (local.get $keys) (local.get $pos)))
          ;; Identity first: a hoisted constant key used at both the store and
          ;; the load is the same object, so no hashing or byte compare at all.
          (if (ref.eq (ref.cast (ref null eq) (local.get $sk)) (ref.cast (ref null eq) (local.get $k)))
            (then (return (local.get $pos))))
          (if (local.get $is_str)
            (then
              ;; A string key only ever equals another string; every stored key
              ;; was hashed on insert, so compare the cached hashes first.
              (if (ref.test (ref $LuaString) (local.get $sk))
                (then (if (i32.eq (struct.get $LuaString $hash (ref.cast (ref $LuaString) (local.get $sk)))
                                  (local.get $full))
                  (then (if (call $str_eq (local.get $sk) (local.get $k))
                    (then (return (local.get $pos)))))))))
            (else (if (local.get $by_value)
              (then (if (call $lua_eq_raw (local.get $sk) (local.get $k))
                (then (return (local.get $pos))))))))))
      (local.set $h (i32.and (local.get $mask)
        (i32.add (local.get $h) (i32.const 1))))
      (br $probe))
    (i32.const -1))

  ;; Public lookup: returns position in keys[] (>=0) or -1 on miss.
  (func $tab_find (param $t (ref $LuaTable)) (param $k anyref) (result i32)
    (if (i32.eqz (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t))))
      (then (return (i32.const -1))))
    (call $tab_index_lookup (local.get $t) (local.get $k)))

  ;; Hash-part raw lookup: position in keys[] (>=0) or nil. The array part is
  ;; handled by the $tab_get_raw dispatcher below.
  (func $tab_get_hash (param $t (ref $LuaTable)) (param $k anyref) (result anyref)
    (local $i i32) (local $vals (ref null $TArr))
    (local.set $i (call $tab_find (local.get $t) (local.get $k)))
    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return (ref.null any))))
    (local.set $vals (struct.get $LuaTable $vals (local.get $t)))
    (call $tval (array.get $TArr (ref.as_non_null (local.get $vals)) (local.get $i))
                (struct.get $LuaTable $fvals (local.get $t)) (local.get $i)))

  ;; If $k is an integer or integral float in i64 range, returns (value, 1);
  ;; otherwise (0, 0). Mirrors the integer-valued-float normalization in
  ;; $lua_hash, so t[2] and t[2.0] address the same array slot.
  (func $as_arr_key (param $k anyref) (result i64 i32)
    (local $f f64)
    (if (call $is_int (local.get $k))
      (then (return (call $as_int (local.get $k)) (i32.const 1))))
    (if (call $is_float (local.get $k))
      (then
        (local.set $f (call $as_float (local.get $k)))
        (if (i32.and (f64.eq (local.get $f) (f64.trunc (local.get $f)))
                     (i32.and (f64.ge (local.get $f) (f64.const -9.2233720368547758e+18))
                              (f64.lt (local.get $f) (f64.const  9.2233720368547758e+18))))
          (then (return (i64.trunc_f64_s (local.get $f)) (i32.const 1))))))
    (return (i64.const 0) (i32.const 0)))

  ;; Ensure the array part can hold $need slots (initial 4, doubling).
  (func $arr_ensure (param $t (ref $LuaTable)) (param $need i32)
    (local $a (ref null $TArr)) (local $cap i32) (local $na (ref $TArr))
    (local.set $a (struct.get $LuaTable $arr (local.get $t)))
    (if (ref.is_null (local.get $a))
      (then
        (local.set $cap (i32.const 4))
        (if (i32.gt_s (local.get $need) (local.get $cap)) (then (local.set $cap (local.get $need))))
        (struct.set $LuaTable $arr (local.get $t)
          (array.new $TArr (ref.null any) (local.get $cap)))
        (return)))
    (local.set $cap (array.len (ref.as_non_null (local.get $a))))
    (if (i32.gt_s (local.get $need) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (if (i32.gt_s (local.get $need) (local.get $cap)) (then (local.set $cap (local.get $need))))
        (local.set $na (array.new $TArr (ref.null any) (local.get $cap)))
        (array.copy $TArr $TArr (local.get $na) (i32.const 0)
          (ref.as_non_null (local.get $a)) (i32.const 0)
          (array.len (ref.as_non_null (local.get $a))))
        (struct.set $LuaTable $arr (local.get $t) (local.get $na))
        (if (i32.eqz (ref.is_null (struct.get $LuaTable $farr (local.get $t))))
          (then (struct.set $LuaTable $farr (local.get $t)
            (call $farr_grow (ref.as_non_null (struct.get $LuaTable $farr (local.get $t)))
                             (local.get $cap)
                             (array.len (ref.as_non_null (struct.get $LuaTable $farr (local.get $t)))))))))))

  ;; Spill the array part's live entries into the hash part and clear it.
  ;; Called when an append would grow a part that is mostly holes.
  (func $tab_demote (param $t (ref $LuaTable))
    (local $i i32) (local $alen i32) (local $a (ref $TArr)) (local $fa (ref null $FArr))
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    (if (i32.eqz (local.get $alen)) (then (return)))
    (local.set $a (ref.as_non_null (struct.get $LuaTable $arr (local.get $t))))
    (local.set $fa (struct.get $LuaTable $farr (local.get $t)))
    (struct.set $LuaTable $alen (local.get $t) (i32.const 0))
    (struct.set $LuaTable $arr  (local.get $t) (ref.null $TArr))
    (struct.set $LuaTable $farr (local.get $t) (ref.null $FArr))
    (local.set $i (i32.const 0))
    (loop $lp
      (if (i32.lt_s (local.get $i) (local.get $alen))
        (then
          (if (i32.eqz (ref.is_null (array.get $TArr (local.get $a) (local.get $i))))
            (then (call $tab_set_hash (local.get $t)
              (call $make_int (i64.extend_i32_s (i32.add (local.get $i) (i32.const 1))))
              (call $tval (array.get $TArr (local.get $a) (local.get $i)) (local.get $fa) (local.get $i)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $lp)))))

  ;; Raw read of a 1-based integer key: hits the $arr part directly when in
  ;; range (no key boxing, no $as_arr_key, no __index chain; a hole reads as
  ;; nil), else falls back to the hash part. Used by table.sort/insert/remove/
  ;; move and table.concat, which read raw.
  (func $tab_get_arr_idx (param $t (ref $LuaTable)) (param $idx i32) (result anyref)
    (if (i32.and (i32.ge_s (local.get $idx) (i32.const 1))
                 (i32.le_s (local.get $idx) (struct.get $LuaTable $alen (local.get $t))))
      (then (return (call $tval (array.get $TArr
        (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
        (i32.sub (local.get $idx) (i32.const 1)))
        (struct.get $LuaTable $farr (local.get $t)) (i32.sub (local.get $idx) (i32.const 1))))))
    (call $tab_get_hash (local.get $t)
      (call $make_int (i64.extend_i32_s (local.get $idx)))))

  ;; Raw write of a 1-based integer key, mirroring $tab_get_arr_idx. An in-range
  ;; overwrite hits $arr directly; everything else (append/grow/delete/sparse)
  ;; defers to the boxed-key raw setter, which keeps the array-part invariants.
  (func $tab_set_arr_idx (param $t (ref $LuaTable)) (param $idx i32) (param $v anyref)
    (if (i32.and (i32.and (i32.ge_s (local.get $idx) (i32.const 1))
                          (i32.le_s (local.get $idx) (struct.get $LuaTable $alen (local.get $t))))
                 (i32.eqz (ref.is_null (local.get $v))))
      (then
        (array.set $TArr
          (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
          (i32.sub (local.get $idx) (i32.const 1)) (local.get $v))
        (return)))
    (call $tab_set (local.get $t)
      (call $make_int (i64.extend_i32_s (local.get $idx))) (local.get $v)))

  ;; Raw lookup `t[k]` (no metamethods): array part fast path, else hash part.
  (func $tab_get_raw (param $t (ref $LuaTable)) (param $k anyref) (result anyref)
    (local $val i64) (local $ok i32) (local $alen i32)
    ;; String keys (field access, the common case) never live in the array
    ;; part: skip the numeric-key normalization and go straight to the hash.
    (if (ref.test (ref $LuaString) (local.get $k))
      (then (return (call $tab_get_hash (local.get $t) (local.get $k)))))
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    (call $as_arr_key (local.get $k))
    (local.set $ok)
    (local.set $val)
    (if (i32.and (local.get $ok)
                 (i32.and (i64.ge_s (local.get $val) (i64.const 1))
                          (i64.le_s (local.get $val) (i64.extend_i32_s (local.get $alen)))))
      (then (return (call $tval (array.get $TArr
        (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
        (i32.wrap_i64 (i64.sub (local.get $val) (i64.const 1))))
        (struct.get $LuaTable $farr (local.get $t))
        (i32.wrap_i64 (i64.sub (local.get $val) (i64.const 1)))))))
    (call $tab_get_hash (local.get $t) (local.get $k)))

  ;; Raw hash-part read of a string key whose hash is $full (no array part —
  ;; strings never live there — and no __index), through the
  ;; string-specialized probe. A deleted entry reads as nil like any miss.
  (func $tab_get_str_h (param $t (ref $LuaTable)) (param $k (ref $LuaString)) (param $full i32) (result anyref)
    (local $i i32)
    (local.set $i (call $tab_find_str (local.get $t) (local.get $k) (local.get $full)))
    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return (ref.null any))))
    (call $tval (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $i))
                (struct.get $LuaTable $fvals (local.get $t)) (local.get $i)))

  ;; $tab_get_str_h with the key's cached hash: the metamethod fetch path.
  (func $tab_get_str (param $t (ref $LuaTable)) (param $k (ref $LuaString)) (result anyref)
    (call $tab_get_str_h (local.get $t) (local.get $k) (call $str_hash (local.get $k))))

  ;; Apply `t[val] = v` (val an unboxed integer key) to the array part only.
  ;; The array part holds integer keys 1..$alen and may contain holes: a nil
  ;; written inside it just clears the slot (no key moves, so a traversal that
  ;; clears fields as it goes is undisturbed), and deleting the last element
  ;; trims the trailing holes ($arr_trim), so $arr[$alen-1] is never nil and
  ;; `#t` stays O(1). A key just past the end appends ($arr_append). Returns 1
  ;; if handled; 0 tells the caller to use the hash part (a sparse or
  ;; out-of-range key, or an append the array part declined). Shared by the
  ;; boxed ($tab_set) and raw-key ($tab_set_ik) entry points.
  (func $tab_set_arr (param $t (ref $LuaTable)) (param $val i64) (param $v anyref) (result i32)
    (local $alen i32)
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    (if (i32.and (i64.ge_s (local.get $val) (i64.const 1))
                 (i64.le_s (local.get $val) (i64.extend_i32_s (local.get $alen))))
      (then
        (array.set $TArr (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
          (i32.wrap_i64 (i64.sub (local.get $val) (i64.const 1))) (local.get $v))
        (if (i32.and (ref.is_null (local.get $v))
                     (i64.eq (local.get $val) (i64.extend_i32_s (local.get $alen))))
          (then (call $arr_trim (local.get $t))))
        (return (i32.const 1))))
    (if (i64.eq (local.get $val) (i64.add (i64.extend_i32_s (local.get $alen)) (i64.const 1)))
      (then (return_call $arr_append (local.get $t) (local.get $v))))
    (i32.const 0))

  ;; `t[#array part + 1] = v`: append to the array part, then absorb any
  ;; integer keys sitting in the hash that now continue the sequence. Returns
  ;; 0 (the store belongs in the hash part) for nil, at the $arr_max cap —
  ;; which keeps a runaway sequence (e.g. `a[i]=i` to math.huge) from tripping
  ;; the engine's array-size limit with an uncatchable trap — and when growing
  ;; a part that is mostly holes: that moves its live entries to the hash
  ;; instead, so a queue's dead front can't pin memory forever (the scan is
  ;; paid for by the copy the growth would have made).
  (func $arr_append (param $t (ref $LuaTable)) (param $v anyref) (result i32)
    (local $alen i32) (local $arr (ref null $TArr)) (local $hv anyref)
    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    (if (i32.ge_s (local.get $alen) (global.get $arr_max)) (then (return (i32.const 0))))
    (local.set $arr (struct.get $LuaTable $arr (local.get $t)))
    (if (i32.eqz (ref.is_null (local.get $arr)))
      (then (if (i32.ge_s (local.get $alen) (array.len (ref.as_non_null (local.get $arr))))
        (then (if (i32.gt_s (i32.shl (call $arr_holes (local.get $t)) (i32.const 1)) (local.get $alen))
          (then (call $tab_demote (local.get $t))
                (return (i32.const 0))))))))
    (call $arr_ensure (local.get $t) (i32.add (local.get $alen) (i32.const 1)))
    (array.set $TArr (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
      (local.get $alen) (local.get $v))
    (local.set $alen (i32.add (local.get $alen) (i32.const 1)))
    (struct.set $LuaTable $alen (local.get $t) (local.get $alen))
    ;; nothing to absorb when the hash part has no keys
    (if (i32.eqz (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t))))
      (then (return (i32.const 1))))
    (loop $mig
      (local.set $hv (if (result anyref) (i32.lt_s (local.get $alen) (global.get $arr_max))
        (then (call $tab_get_hash (local.get $t)
          (call $make_int (i64.add (i64.extend_i32_s (local.get $alen)) (i64.const 1)))))
        (else (ref.null any))))
      (if (i32.eqz (ref.is_null (local.get $hv)))
        (then
          (call $arr_ensure (local.get $t) (i32.add (local.get $alen) (i32.const 1)))
          (array.set $TArr (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
            (local.get $alen) (local.get $hv))
          (call $tab_set_hash (local.get $t)
            (call $make_int (i64.add (i64.extend_i32_s (local.get $alen)) (i64.const 1)))
            (ref.null any))
          (local.set $alen (i32.add (local.get $alen) (i32.const 1)))
          (struct.set $LuaTable $alen (local.get $t) (local.get $alen))
          (br $mig))))
    (i32.const 1))

;; Whether an append to $t's array part must take $arr_append: a
  ;; metatable (__newindex sees absent keys), integer keys in the hash part
  ;; it could absorb, or no room left in the array. Codegen appends inline
  ;; otherwise (src/codegen/arrays.c, emit_ix_set).
  (func $arr_append_blocked (param $t (ref null $LuaTable)) (result i32)
    (local $a (ref null $TArr))
    (if (i32.eqz (ref.is_null (struct.get $LuaTable $meta (local.get $t)))) (then (return (i32.const 1))))
    (if (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t))) (then (return (i32.const 1))))
    (local.set $a (struct.get $LuaTable $arr (local.get $t)))
    (if (ref.is_null (local.get $a)) (then (return (i32.const 1))))
    (i32.ge_u (struct.get $LuaTable $alen (local.get $t)) (array.len (ref.as_non_null (local.get $a)))))

  ;; Drop trailing holes from the array part after its last element was
  ;; cleared, restoring "$arr[$alen-1] is not nil" (so $alen is a border).
  ;; Amortized O(1): each hole is trimmed at most once per time it was made.
  (func $arr_trim (param $t (ref $LuaTable))
    (local $alen i32) (local $a (ref null $TArr))
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    (local.set $a (struct.get $LuaTable $arr (local.get $t)))
    (block $done (loop $lp
      (br_if $done (i32.eqz (local.get $alen)))
      (br_if $done (i32.eqz (ref.is_null (array.get $TArr (ref.as_non_null (local.get $a))
                                                         (i32.sub (local.get $alen) (i32.const 1))))))
      (local.set $alen (i32.sub (local.get $alen) (i32.const 1)))
      (br $lp)))
    (struct.set $LuaTable $alen (local.get $t) (local.get $alen)))

  ;; Number of holes (nil slots) among the array part's 1..$alen.
  (func $arr_holes (param $t (ref $LuaTable)) (result i32)
    (local $i i32) (local $alen i32) (local $n i32) (local $a (ref null $TArr))
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    (local.set $a (struct.get $LuaTable $arr (local.get $t)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $alen)))
      (if (ref.is_null (array.get $TArr (ref.as_non_null (local.get $a)) (local.get $i)))
        (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $n))

  ;; `t[k] = v` raw set (no metamethods; that is $lua_tabset): array fast path or
  ;; hash part.
  (func $tab_set (param $t (ref $LuaTable)) (param $k anyref) (param $v anyref)
    (local $val i64) (local $ok i32)
    ;; The single raw-set chokepoint: reject a nil or NaN key (Lua §3.4.4),
    ;; matching rawset, so t[nil]=v / t[0/0]=v and {[nil]=v} all raise rather
    ;; than silently store. (A nil VALUE — deletion — is fine; this guards $k.)
    ;; String keys need none of the checks below and never hit the array part.
    (if (ref.test (ref $LuaString) (local.get $k))
      (then (call $tab_set_hash (local.get $t) (local.get $k) (local.get $v)) (return)))
    (if (ref.is_null (local.get $k))
      (then (call $throw_lit (i32.const 261) (i32.const 18))))   ;; "table index is nil"
    (if (call $is_float (local.get $k))
      (then (if (f64.ne (call $as_float (local.get $k)) (call $as_float (local.get $k)))
        (then (call $throw_lit (i32.const 279) (i32.const 18))))))   ;; "table index is NaN"
    (call $as_arr_key (local.get $k))
    (local.set $ok)
    (local.set $val)
    ;; A key with an exact integer value — an integer, or an integral float in
    ;; i64 range — is normalized to an integer key (Lua §3.4.3): t[3.0] and t[3]
    ;; address the same entry, and iteration must report the key as an integer.
    ;; The array part is integer-indexed already; for the hash part re-box the
    ;; value with $make_int so a stored integral-float key isn't kept as a float.
    (if (local.get $ok)
      (then
        (if (call $tab_set_arr (local.get $t) (local.get $val) (local.get $v))
          (then (return)))
        (call $tab_set_hash (local.get $t) (call $make_int (local.get $val)) (local.get $v))
        (return)))
    (call $tab_set_hash (local.get $t) (local.get $k) (local.get $v)))

  ;; Raw set with an already-unboxed integer key (skips $as_arr_key, and the key
  ;; make_int unless the value spills to the hash part). Used by codegen.
  (func $tab_set_ik (param $t (ref $LuaTable)) (param $k i64) (param $v anyref)
    (if (call $tab_set_arr (local.get $t) (local.get $k) (local.get $v))
      (then (return)))
    (call $tab_set_hash (local.get $t) (call $make_int (local.get $k)) (local.get $v)))

  ;; --- unboxed float stores (codegen entry points) ---
  ;; Store f64 under a string key with known hash: present -> mark + fvals;
  ;; absent -> insert the marker, then fill fvals at the new index.
  (func $tab_set_f_hash_str (param $t (ref $LuaTable)) (param $k (ref $LuaString)) (param $full i32) (param $f f64)
    (local $i i32)
    (local.set $i (call $tab_find_str (local.get $t) (local.get $k) (local.get $full)))
    (if (i32.lt_s (local.get $i) (i32.const 0))
      (then
        (call $tab_insert_new (local.get $t) (local.get $k) (global.get $g_fmark) (local.get $full))
        (local.set $i (i32.sub (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t))) (i32.const 1))))
      (else
        (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $i)
          (global.get $g_fmark))))
    (array.set $FArr (call $fvals_ensure (local.get $t)) (local.get $i) (local.get $f)))
  (func $tab_set_f_hash (param $t (ref $LuaTable)) (param $k anyref) (param $f f64)
    (local $i i32) (local $full i32)
    (local.set $full (call $lua_hash (local.get $k)))
    (local.set $i (if (result i32) (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t)))
      (then (call $tab_index_lookup_h (local.get $t) (local.get $k) (local.get $full)))
      (else (i32.const -1))))
    (if (i32.lt_s (local.get $i) (i32.const 0))
      (then
        (call $tab_insert_new (local.get $t) (local.get $k) (global.get $g_fmark) (local.get $full))
        (local.set $i (i32.sub (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t))) (i32.const 1))))
      (else
        (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $i)
          (global.get $g_fmark))))
    (array.set $FArr (call $fvals_ensure (local.get $t)) (local.get $i) (local.get $f)))


  (func $tab_set_hash (param $t (ref $LuaTable)) (param $k anyref) (param $v anyref)
    (local $i i32) (local $full i32)
    (local.set $full (call $lua_hash (local.get $k)))
    (local.set $i (if (result i32) (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t)))
      (then (call $tab_index_lookup_h (local.get $t) (local.get $k) (local.get $full)))
      (else (i32.const -1))))
    (if (i32.ge_s (local.get $i) (i32.const 0))
      (then
        ;; Existing slot: update in place, or *lazily* delete. We keep the
        ;; key in keys[] and only clear vals[$i] to nil (Lua never stores a
        ;; nil value, so "vals[i] == nil" is exactly "entry i is deleted").
        ;; This leaves the entry findable, so next() can resume from a key
        ;; that was removed mid-traversal — the common `for k in pairs(t) do
        ;; t[k] = nil end` idiom — instead of seeing it as an invalid key.
        ;; Dead entries are reclaimed by $tab_index_rebuild on the next
        ;; index growth, keeping churn bounded.
        (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))
          (local.get $i) (local.get $v))
        (return)))
    ;; not found: nil value is a no-op; else append a new entry.
    (if (ref.is_null (local.get $v)) (then (return)))
    (call $tab_insert_new (local.get $t) (local.get $k) (local.get $v) (local.get $full)))

  ;; String-key store with a known hash: the constant-key setter's path.
  (func $tab_set_hash_str (param $t (ref $LuaTable)) (param $k (ref $LuaString)) (param $full i32) (param $v anyref)
    (local $i i32)
    (local.set $i (call $tab_find_str (local.get $t) (local.get $k) (local.get $full)))
    (if (i32.ge_s (local.get $i) (i32.const 0))
      (then
        (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))
          (local.get $i) (local.get $v))
        (return)))
    (if (ref.is_null (local.get $v)) (then (return)))
    (call $tab_insert_new (local.get $t) (local.get $k) (local.get $v) (local.get $full)))

  ;; Append a key known to be absent (hash $full) to keys/vals and probe-insert
  ;; it into the index, growing/rebuilding as needed. Shared by the boxed and
  ;; string-key setters.
  (func $tab_insert_new (param $t (ref $LuaTable)) (param $k anyref) (param $v anyref) (param $full i32)
    (local $sh (ref $Shape)) (local $n i32)
    (if (i32.eqz (struct.get $LuaTable $own (local.get $t)))
      (then
        ;; Shared shape: move to the child shape that adds $k, keeping the
        ;; layout shareable — unless the table is turning into a dictionary
        ;; (a non-string key, or too many keys): that gets a private shape.
        (if (i32.and (ref.test (ref $LuaString) (local.get $k))
                     (i32.lt_s (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t)))
                               (global.get $shape_share_max)))
          (then
            (local.set $sh (call $shape_child (struct.get $LuaTable $shape (local.get $t))
                             (ref.cast (ref $LuaString) (local.get $k)) (local.get $full)))
            (local.set $n (struct.get $Shape $n (local.get $sh)))
            (call $vals_reserve (local.get $t) (local.get $n))
            (struct.set $LuaTable $shape (local.get $t) (local.get $sh))
            (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))
              (i32.sub (local.get $n) (i32.const 1)) (local.get $v))
            (return)))
        (call $tab_own (local.get $t))))
    (call $tab_insert_owned (local.get $t) (local.get $k) (local.get $v) (local.get $full)))

  ;; Append a new key to a table's private shape and its value to $vals, then
  ;; probe-insert it into the index, reusing the first tombstone in the probe
  ;; chain if any (so churn doesn't grow $used). The index is kept under 50%
  ;; occupancy (keys + tombstones = $used): a rebuild doubles it and drops
  ;; lazily-deleted entries.
  (func $tab_insert_owned (param $t (ref $LuaTable)) (param $k anyref) (param $v anyref) (param $full i32)
    (local $sh (ref $Shape)) (local $n i32) (local $mask i32) (local $idx (ref $IArr))
    (local $keys (ref $TArr)) (local $nk (ref $TArr)) (local $h i32) (local $slot i32) (local $ftomb i32)
    (local.set $sh (struct.get $LuaTable $shape (local.get $t)))
    (if (i32.ge_u (i32.shl (i32.add (struct.get $Shape $used (local.get $sh)) (i32.const 1)) (i32.const 1))
                  (i32.add (struct.get $Shape $mask (local.get $sh)) (i32.const 1)))
      (then
        (call $tab_index_rebuild (local.get $t))
        ;; (compaction may have lowered the append position, under a new shape)
        (local.set $sh (struct.get $LuaTable $shape (local.get $t)))))
    (local.set $n (struct.get $Shape $n (local.get $sh)))
    (local.set $keys (struct.get $Shape $keys (local.get $sh)))
    (if (i32.ge_s (local.get $n) (array.len (local.get $keys)))
      (then
        (if (i32.gt_u (local.get $n) (i32.const 8388608))
          (then (call $throw_lit (i32.const 341) (i32.const 14))))   ;; "table overflow"
        (local.set $nk (array.new $TArr (ref.null any) (i32.shl (local.get $n) (i32.const 1))))
        (array.copy $TArr $TArr (local.get $nk) (i32.const 0) (local.get $keys) (i32.const 0) (local.get $n))
        (struct.set $Shape $keys (local.get $sh) (local.get $nk))
        (local.set $keys (local.get $nk))))
    (call $vals_reserve (local.get $t) (i32.add (local.get $n) (i32.const 1)))
    (array.set $TArr (local.get $keys) (local.get $n) (local.get $k))
    (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $n) (local.get $v))
    (struct.set $Shape $n (local.get $sh) (i32.add (local.get $n) (i32.const 1)))
    (local.set $idx (struct.get $Shape $idx (local.get $sh)))
    (local.set $mask (struct.get $Shape $mask (local.get $sh)))
    (local.set $h (i32.and (local.get $mask) (local.get $full)))
    (local.set $ftomb (i32.const -1))
    (loop $probe
      (local.set $slot (array.get $IArr (local.get $idx) (local.get $h)))
      (if (i32.eqz (local.get $slot))
        (then
          (if (i32.ge_s (local.get $ftomb) (i32.const 0))
            (then  ;; reuse a tombstone — occupied count ($used) unchanged
              (array.set $IArr (local.get $idx) (local.get $ftomb) (i32.add (local.get $n) (i32.const 1))))
            (else  ;; consume a fresh empty slot — one more occupied
              (array.set $IArr (local.get $idx) (local.get $h) (i32.add (local.get $n) (i32.const 1)))
              (struct.set $Shape $used (local.get $sh)
                (i32.add (struct.get $Shape $used (local.get $sh)) (i32.const 1)))))
          (return)))
      (if (i32.lt_s (local.get $slot) (i32.const 0))
        (then (if (i32.lt_s (local.get $ftomb) (i32.const 0))
          (then (local.set $ftomb (local.get $h))))))
      (local.set $h (i32.and (local.get $mask) (i32.add (local.get $h) (i32.const 1))))
      (br $probe)))


  ;; Bootstrap-only hash insert: append a fresh, unique key into the hash part,
  ;; self-growing keys/vals and self-rehashing the index as needed. Unlike
  ;; $tab_set_hash it never calls $tab_grow / $tab_index_rebuild / $tab_demote /
  ;; the array-part setter, so a program that performs no table writes of its
  ;; own leaves that whole write path unreferenced and the DCE pass drops it.
  ;; Preconditions (guaranteed by $stdlib_init): the key is absent (so we can
  ;; skip the find-and-update step) and string-typed (so it belongs in the hash
  ;; part, never the array prefix).
  (func $tab_bootstrap_set (param $t (ref $LuaTable)) (param $k anyref) (param $v anyref)
    (call $tab_own (local.get $t))
    (call $tab_insert_owned (local.get $t) (local.get $k) (local.get $v) (call $lua_hash (local.get $k))))

  ;; Raw array-border length (the `#` operator's table case; __len is handled in
  ;; $lua_len). A border n satisfies t[n] ~= nil and t[n+1] == nil. Raw access
  ;; only — __index must NOT be consulted (consulting it would also never
  ;; terminate when __index returns non-nil for every key).
  ;;
  ;; Fast path: the array part's last slot is never nil, so if nothing in the
  ;; hash part continues it (t[alen+1] is nil) then $alen is a border.
  ;; Otherwise keep walking the hash part from there until the run ends.
  (func $tab_len (param $t (ref $LuaTable)) (result i32)
    (local $i i32) (local $alen i32)
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    ;; Common case: the sequence lives entirely in the array part — always so
    ;; when the hash part has no keys.
    (if (i32.eqz (struct.get $Shape $n (struct.get $LuaTable $shape (local.get $t))))
      (then (return (local.get $alen))))
    (if (ref.is_null (call $tab_get_hash (local.get $t)
          (call $make_int (i64.extend_i32_s (i32.add (local.get $alen) (i32.const 1))))))
      (then (return (local.get $alen))))
    ;; The run spills into the hash part; continue raw from alen+1.
    (local.set $i (i32.add (local.get $alen) (i32.const 1)))
    (block $done (loop $lp
      (br_if $done (ref.is_null (call $tab_get_hash (local.get $t)
        (call $make_int (i64.extend_i32_s (i32.add (local.get $i) (i32.const 1)))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $i))
