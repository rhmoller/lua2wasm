;; Lua indexing: t[k] reads and writes through __index / __newindex, the
;; inline-cached constant-key and method sites, and the typed entry points
;; specialized code calls.

  ;; Lookup that walks the __index metamethod chain (with cycle limit).
  (func $tab_get (param $t (ref $LuaTable)) (param $k anyref) (result anyref)
    (local $v anyref)
    (local.set $v (call $tab_get_raw (local.get $t) (local.get $k)))
    (if (i32.eqz (ref.is_null (local.get $v))) (then (return (local.get $v))))
    (call $tab_get_miss (local.get $t) (local.get $k) (i32.const 64)))

  ;; The __index chain after a raw miss on $t: a table __index continues the
  ;; lookup there (recursing with a depth cap against cycles), a function
  ;; __index is called, anything else yields nil.
  (func $tab_get_miss (param $t (ref $LuaTable)) (param $k anyref) (param $depth i32) (result anyref)
    (local $v anyref) (local $mt (ref null $LuaTable)) (local $idx anyref)
    (local $nt (ref $LuaTable))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt)) (then (return (ref.null any))))
    (local.set $idx (call $tab_get_str (ref.as_non_null (local.get $mt))
                                        (ref.as_non_null (global.get $g_mkey_index))))
    (if (ref.is_null (local.get $idx)) (then (return (ref.null any))))
    (if (ref.test (ref $LuaTable) (local.get $idx))
      (then
        (if (i32.le_s (local.get $depth) (i32.const 1)) (then (return (ref.null any))))
        (local.set $nt (ref.cast (ref $LuaTable) (local.get $idx)))
        (local.set $v (call $tab_get_raw (local.get $nt) (local.get $k)))
        (if (i32.eqz (ref.is_null (local.get $v))) (then (return (local.get $v))))
        (return (call $tab_get_miss (local.get $nt) (local.get $k)
                                    (i32.sub (local.get $depth) (i32.const 1))))))
    (if (ref.test (ref $LuaClosure) (local.get $idx))
      (then (return
        (call $call_mm1 (local.get $idx) (local.get $t) (local.get $k) (ref.null any) (i32.const 2)))))
    (ref.null any))

  ;; `t.name` / `t["lit"]` read with a compile-time constant string key — the
  ;; codegen entry point for field access. The key is a hoisted module global,
  ;; so it is the very object stored by a constructor or assignment using the
  ;; same literal, and the lookup usually resolves on identity. Strings never
  ;; hit the array part, so this goes straight to the hash part, then the
  ;; __index chain; a non-table receiver defers to $lua_index (string lib /
  ;; error).
  (func $lua_index_sk (param $tv anyref) (param $k (ref $LuaString)) (param $line i32) (result anyref)
    (local $t (ref $LuaTable)) (local $v anyref) (local $full i32)
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then
        (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
        ;; Callers pass hoisted constants (codegen kstr globals), whose hash is
        ;; precomputed and never 0, so read the field instead of calling
        ;; $str_hash.
        (local.set $full (struct.get $LuaString $hash (local.get $k)))
        (local.set $v (call $tab_get_str_h (local.get $t) (local.get $k) (local.get $full)))
        (if (i32.eqz (ref.is_null (local.get $v))) (then (return (local.get $v))))
        (return (call $tab_get_miss_str (local.get $t) (local.get $k) (local.get $full) (i32.const 64)))))
    (call $lua_index (local.get $tv) (local.get $k) (local.get $line)))

  ;; --- inline-cached constant-key access ---
  ;; `t.name` read: when the table's shape is the site's cached shape the
  ;; value is at the cached position; anything else (another shape, a nil
  ;; value, a non-table) takes $lua_index_ic_miss, which refills the cache.
  (func $lua_index_ic (param $tv anyref) (param $k (ref $LuaString)) (param $line i32) (param $ic (ref $IC))
                      (result anyref)
    (local $t (ref $LuaTable)) (local $v anyref) (local $pos i32)
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then
        (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
        (if (ref.eq (struct.get $LuaTable $shape (local.get $t)) (struct.get $IC $shape (local.get $ic)))
          (then
            (local.set $pos (struct.get $IC $pos (local.get $ic)))
            (local.set $v (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))
                                           (local.get $pos)))
            (if (ref.test (ref $FMark) (local.get $v))
              (then (return (call $make_float (array.get $FArr
                (ref.as_non_null (struct.get $LuaTable $fvals (local.get $t))) (local.get $pos))))))
            (if (i32.eqz (ref.is_null (local.get $v))) (then (return (local.get $v))))))))
    (return_call $lua_index_ic_miss (local.get $tv) (local.get $k) (local.get $line) (local.get $ic)))
  ;; Cache the key's position for the table's shape (a key present with a nil
  ;; value is cached too: the hit path treats nil as a miss), then do the
  ;; ordinary lookup.
  (func $ic_fill (param $tv anyref) (param $k (ref $LuaString)) (param $ic (ref $IC))
    (local $t (ref $LuaTable)) (local $i i32)
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $tv))) (then (return)))
    (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
    (local.set $i (call $tab_find_str (local.get $t) (local.get $k) (struct.get $LuaString $hash (local.get $k))))
    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return)))
    (struct.set $IC $shape (local.get $ic) (struct.get $LuaTable $shape (local.get $t)))
    (struct.set $IC $pos (local.get $ic) (local.get $i)))
  (func $lua_index_ic_miss (param $tv anyref) (param $k (ref $LuaString)) (param $line i32) (param $ic (ref $IC))
                           (result anyref)
    (call $ic_fill (local.get $tv) (local.get $k) (local.get $ic))
    (call $lua_index_sk (local.get $tv) (local.get $k) (local.get $line)))

  ;; The maybe-typed cell form of $lua_index_ic (see $lua_index_sk_cell).
  (func $lua_index_ic_cell (param $tv anyref) (param $k (ref $LuaString)) (param $line i32) (param $ic (ref $IC))
                           (result i32 i64 f64 anyref)
    (local $t (ref $LuaTable)) (local $v anyref) (local $pos i32)
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then
        (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
        (if (ref.eq (struct.get $LuaTable $shape (local.get $t)) (struct.get $IC $shape (local.get $ic)))
          (then
            (local.set $pos (struct.get $IC $pos (local.get $ic)))
            (local.set $v (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))
                                           (local.get $pos)))
            (if (ref.test (ref $FMark) (local.get $v))
              (then
                (i32.const 2) (i64.const 0)
                (array.get $FArr (ref.as_non_null (struct.get $LuaTable $fvals (local.get $t))) (local.get $pos))
                (ref.null any)
                (return)))
            (if (i32.eqz (ref.is_null (local.get $v)))
              (then (call $unbox_num (local.get $v)) (local.get $v) (return)))))))
    (call $ic_fill (local.get $tv) (local.get $k) (local.get $ic))
    (return_call $lua_index_sk_cell (local.get $tv) (local.get $k) (local.get $line)))

  ;; `t.name = v`: at the cached position a present key — or any key when
  ;; the table has no metatable — is a raw overwrite (nil deletes). An absent
  ;; key under a metatable (__newindex), another shape or a new key takes the
  ;; ordinary setter.
  (func $lua_tabset_ic (param $ic (ref $IC)) (param $tv anyref) (param $k (ref $LuaString)) (param $v anyref)
    (local $t (ref $LuaTable)) (local $pos i32) (local $vals (ref $TArr))
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then
        (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
        (if (ref.eq (struct.get $LuaTable $shape (local.get $t)) (struct.get $IC $shape (local.get $ic)))
          (then
            (local.set $pos (struct.get $IC $pos (local.get $ic)))
            (local.set $vals (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))))
            (if (ref.is_null (struct.get $LuaTable $meta (local.get $t)))
              (then (array.set $TArr (local.get $vals) (local.get $pos) (local.get $v)) (return)))
            (if (i32.eqz (ref.is_null (array.get $TArr (local.get $vals) (local.get $pos))))
              (then (array.set $TArr (local.get $vals) (local.get $pos) (local.get $v)) (return)))))))
    (call $ic_fill (local.get $tv) (local.get $k) (local.get $ic))
    (call $lua_tabset_sk (local.get $tv) (local.get $k) (local.get $v)))
  (func $lua_tabset_ic_f (param $ic (ref $IC)) (param $tv anyref) (param $k (ref $LuaString)) (param $f f64)
    (local $t (ref $LuaTable)) (local $pos i32) (local $vals (ref $TArr))
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then
        (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
        (if (ref.eq (struct.get $LuaTable $shape (local.get $t)) (struct.get $IC $shape (local.get $ic)))
          (then
            (local.set $pos (struct.get $IC $pos (local.get $ic)))
            (local.set $vals (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))))
            (if (i32.or (ref.is_null (struct.get $LuaTable $meta (local.get $t)))
                        (i32.eqz (ref.is_null (array.get $TArr (local.get $vals) (local.get $pos)))))
              (then
                (array.set $TArr (local.get $vals) (local.get $pos) (global.get $g_fmark))
                (array.set $FArr (call $fvals_ensure (local.get $t)) (local.get $pos) (local.get $f))
                (return)))))))
    (call $ic_fill (local.get $tv) (local.get $k) (local.get $ic))
    (call $lua_tabset_sk_f (local.get $tv) (local.get $k) (local.get $f)))

  ;; `obj:m` method lookup. The cached case is the usual class pattern: the
  ;; receiver's (shared) shape lacks the key, its metatable has __index at a
  ;; cached position, that slot still holds the cached class table, and the
  ;; class's shape has the method at a cached position. Five identity checks
  ;; instead of three hash probes; anything else takes $lua_method_ic_miss.
  (func $lua_method_ic (param $tv anyref) (param $k (ref $LuaString)) (param $line i32) (param $ic (ref $MIC))
                       (result anyref)
    (local $t (ref $LuaTable)) (local $m (ref null $LuaTable)) (local $c (ref $LuaTable)) (local $v anyref)
    (block $miss
      (br_if $miss (i32.eqz (ref.test (ref $LuaTable) (local.get $tv))))
      (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
      (br_if $miss (i32.eqz (ref.eq (struct.get $LuaTable $shape (local.get $t)) (struct.get $MIC $s1 (local.get $ic)))))
      (local.set $m (struct.get $LuaTable $meta (local.get $t)))
      (br_if $miss (ref.is_null (local.get $m)))
      (br_if $miss (i32.eqz (ref.eq (struct.get $LuaTable $shape (ref.as_non_null (local.get $m)))
                                    (struct.get $MIC $ms (local.get $ic)))))
      (br_if $miss (i32.eqz (ref.eq
        (ref.cast (ref null eq) (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (ref.as_non_null (local.get $m))))
                                                 (struct.get $MIC $mp (local.get $ic))))
        (struct.get $MIC $c (local.get $ic)))))
      (local.set $c (ref.as_non_null (struct.get $MIC $c (local.get $ic))))
      (br_if $miss (i32.eqz (ref.eq (struct.get $LuaTable $shape (local.get $c)) (struct.get $MIC $cs (local.get $ic)))))
      (local.set $v (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $c)))
                                     (struct.get $MIC $cp (local.get $ic))))
      (br_if $miss (ref.is_null (local.get $v)))
      (br_if $miss (ref.test (ref $FMark) (local.get $v)))
      (return (local.get $v)))
    (return_call $lua_method_ic_miss (local.get $tv) (local.get $k) (local.get $line) (local.get $ic)))
  (func $lua_method_ic_miss (param $tv anyref) (param $k (ref $LuaString)) (param $line i32) (param $ic (ref $MIC))
                            (result anyref)
    (local $t (ref $LuaTable)) (local $m (ref $LuaTable)) (local $c (ref $LuaTable)) (local $full i32)
    (local $mp i32) (local $cp i32) (local $iv anyref)
    (block $nocache
      (br_if $nocache (i32.eqz (ref.test (ref $LuaTable) (local.get $tv))))
      (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
      ;; absence is a property of a shared shape only (an owned one can grow)
      (br_if $nocache (struct.get $LuaTable $own (local.get $t)))
      (local.set $full (struct.get $LuaString $hash (local.get $k)))
      (br_if $nocache (i32.ge_s (call $tab_find_str (local.get $t) (local.get $k) (local.get $full)) (i32.const 0)))
      (br_if $nocache (ref.is_null (struct.get $LuaTable $meta (local.get $t))))
      (local.set $m (ref.as_non_null (struct.get $LuaTable $meta (local.get $t))))
      (local.set $mp (call $tab_find_str (local.get $m) (ref.as_non_null (global.get $g_mkey_index))
                                         (struct.get $LuaString $hash (ref.as_non_null (global.get $g_mkey_index)))))
      (br_if $nocache (i32.lt_s (local.get $mp) (i32.const 0)))
      (local.set $iv (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $m))) (local.get $mp)))
      (br_if $nocache (i32.eqz (ref.test (ref $LuaTable) (local.get $iv))))
      (local.set $c (ref.cast (ref $LuaTable) (local.get $iv)))
      (local.set $cp (call $tab_find_str (local.get $c) (local.get $k) (local.get $full)))
      (br_if $nocache (i32.lt_s (local.get $cp) (i32.const 0)))
      (br_if $nocache (ref.is_null (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $c))) (local.get $cp))))
      (struct.set $MIC $s1 (local.get $ic) (struct.get $LuaTable $shape (local.get $t)))
      (struct.set $MIC $ms (local.get $ic) (struct.get $LuaTable $shape (local.get $m)))
      (struct.set $MIC $mp (local.get $ic) (local.get $mp))
      (struct.set $MIC $c  (local.get $ic) (local.get $c))
      (struct.set $MIC $cs (local.get $ic) (struct.get $LuaTable $shape (local.get $c)))
      (struct.set $MIC $cp (local.get $ic) (local.get $cp)))
    (call $lua_index_sk (local.get $tv) (local.get $k) (local.get $line)))

  ;; $tab_get_miss for a string key with known hash: the method-dispatch path
  ;; (instance miss -> class via __index), every probe string-specialized.
  (func $tab_get_miss_str (param $t (ref $LuaTable)) (param $k (ref $LuaString)) (param $full i32)
                          (param $depth i32) (result anyref)
    (local $v anyref) (local $mt (ref null $LuaTable)) (local $idx anyref)
    (local $nt (ref $LuaTable)) (local $mk (ref $LuaString))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt)) (then (return (ref.null any))))
    (local.set $mk (ref.as_non_null (global.get $g_mkey_index)))
    (local.set $idx (call $tab_get_str_h (ref.as_non_null (local.get $mt)) (local.get $mk)
                                         (struct.get $LuaString $hash (local.get $mk))))
    (if (ref.is_null (local.get $idx)) (then (return (ref.null any))))
    (if (ref.test (ref $LuaTable) (local.get $idx))
      (then
        (if (i32.le_s (local.get $depth) (i32.const 1)) (then (return (ref.null any))))
        (local.set $nt (ref.cast (ref $LuaTable) (local.get $idx)))
        (local.set $v (call $tab_get_str_h (local.get $nt) (local.get $k) (local.get $full)))
        (if (i32.eqz (ref.is_null (local.get $v))) (then (return (local.get $v))))
        (return (call $tab_get_miss_str (local.get $nt) (local.get $k) (local.get $full)
                                        (i32.sub (local.get $depth) (i32.const 1))))))
    (if (ref.test (ref $LuaClosure) (local.get $idx))
      (then (return
        (call $call_mm1 (local.get $idx) (local.get $t) (local.get $k) (ref.null any) (i32.const 2)))))
    (ref.null any))

  ;; `t.name = v` with a constant string key: no metatable means a plain hash
  ;; store (a string key needs none of $tab_set's nil/NaN/integer-key
  ;; normalization); otherwise the boxed setter handles __newindex.
  (func $lua_tabset_sk (param $tv anyref) (param $k (ref $LuaString)) (param $v anyref)
    (local $t (ref $LuaTable)) (local $full i32) (local $i i32) (local $mt (ref null $LuaTable))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $tv)))
      (then (call $throw_lit (i32.const 237) (i32.const 24))))   ;; "attempt to index a value"
    (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
    (local.set $full (struct.get $LuaString $hash (local.get $k)))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt))
      (then (call $tab_set_hash_str (local.get $t) (local.get $k) (local.get $full) (local.get $v))
            (return)))
    ;; Metatable present (an object): __newindex only fires for an ABSENT key,
    ;; so a present one is a plain overwrite — the common `self.x = …` case.
    (local.set $i (call $tab_find_str (local.get $t) (local.get $k) (local.get $full)))
    (if (i32.ge_s (local.get $i) (i32.const 0))
      (then (if (i32.eqz (ref.is_null (array.get $TArr
                  (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $i))))
        (then
          (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))
            (local.get $i) (local.get $v))
          (return)))))
    ;; Absent: no __newindex means a raw insert; otherwise the generic setter
    ;; runs the function/table forms.
    (if (ref.is_null (call $tab_get_str (ref.as_non_null (local.get $mt))
                                        (ref.as_non_null (global.get $g_mkey_newindex))))
      (then (call $tab_set_hash_str (local.get $t) (local.get $k) (local.get $full) (local.get $v))
            (return)))
    (call $lua_tabset (local.get $tv) (local.get $k) (local.get $v)))

  ;; Lua-spec lookup `t[k]` on an arbitrary value. Tables go through
  ;; tab_get (which already walks __index); strings transparently
  ;; redirect to the `string` library (the implicit per-type metatable
  ;; in reference Lua). Anything else throws an error string carrying
  ;; the caller's source line so user code sees a real message instead
  ;; of a wasm ref.cast trap.
  (func $lua_index (param $v anyref) (param $k anyref) (param $line i32) (result anyref)
    (local $err anyref) (local $tab anyref)
    (if (ref.test (ref $LuaTable) (local.get $v))
      (then (return (call $tab_get
        (ref.cast (ref $LuaTable) (local.get $v)) (local.get $k)))))
    (if (ref.test (ref $LuaString) (local.get $v))
      (then
        ;; Resolve through the string metatable's __index (the string library
        ;; table, captured when the metatable was first built) rather than a
        ;; live _G.string read — so reassigning `string` doesn't break methods,
        ;; matching reference Lua, and any __index chain on that table is
        ;; honoured. ($get_string_mt caches, so this is also one fewer hash
        ;; lookup than re-fetching _G.string each time.)
        (local.set $tab (call $tab_get_raw (call $get_string_mt)
          (ref.as_non_null (global.get $g_mkey_index))))
        (if (ref.test (ref $LuaTable) (local.get $tab))
          (then (return (call $tab_get
            (ref.cast (ref $LuaTable) (local.get $tab)) (local.get $k)))))
        (return (ref.null any))))
    ;; Other types (nil, number, boolean, ...): "attempt to index a value",
    ;; matching the write path ($lua_tabset) and rawget. We carry the index
    ;; expression's own source line ($line) rather than the topmost frame's,
    ;; so build the message directly instead of via $throw_lit.
    (local.set $err (struct.new $LuaString
      (array.new_data $LuaArr $str_data (i32.const 237) (i32.const 24)) (i32.const 0)))
    (throw $LuaError (call $prefix_error_msg
      (ref.as_non_null (global.get $g_src_name))
      (local.get $line)
      (ref.cast (ref $LuaString) (local.get $err)))))

  (func $get_metamethod (param $v anyref) (param $key (ref $LuaString)) (result anyref)
    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v))) (then (return (ref.null any))))
    (local.set $t (ref.cast (ref $LuaTable) (local.get $v)))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt)) (then (return (ref.null any))))
    (call $tab_get_str (ref.as_non_null (local.get $mt)) (local.get $key)))

  ;; `t[k] = v` with __newindex dispatch and an unboxed integer key — where
  ;; `t[<int-typed>] = v` goes when the codegen's inline array-part write misses
  ;; (src/codegen/arrays.c). No metatable -> raw set with the raw key (no
  ;; boxing); otherwise fall back to the boxed-key setter for __newindex.
  (func $lua_tabset_ik (param $tv anyref) (param $k i64) (param $v anyref)
    (local $t (ref $LuaTable))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $tv)))
      (then (call $throw_lit (i32.const 237) (i32.const 24))))   ;; "attempt to index a value"
    (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
    (if (ref.is_null (struct.get $LuaTable $meta (local.get $t)))
      (then (call $tab_set_ik (local.get $t) (local.get $k) (local.get $v)) (return)))
    (call $lua_tabset (local.get $tv) (call $make_int (local.get $k)) (local.get $v)))
  ;; `t.name = <f64>` (constant key). Mirrors $lua_tabset_sk's metatable rules.
  (func $lua_tabset_sk_f (param $tv anyref) (param $k (ref $LuaString)) (param $f f64)
    (local $t (ref $LuaTable)) (local $full i32) (local $i i32) (local $mt (ref null $LuaTable))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $tv)))
      (then (call $throw_lit (i32.const 237) (i32.const 24))))   ;; "attempt to index a value"
    (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
    (local.set $full (struct.get $LuaString $hash (local.get $k)))
    (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
    (if (ref.is_null (local.get $mt))
      (then (call $tab_set_f_hash_str (local.get $t) (local.get $k) (local.get $full) (local.get $f))
            (return)))
    (local.set $i (call $tab_find_str (local.get $t) (local.get $k) (local.get $full)))
    (if (i32.ge_s (local.get $i) (i32.const 0))
      (then (if (i32.eqz (ref.is_null (array.get $TArr
                  (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $i))))
        (then
          (array.set $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t))) (local.get $i)
            (global.get $g_fmark))
          (array.set $FArr (call $fvals_ensure (local.get $t)) (local.get $i) (local.get $f))
          (return)))))
    (if (ref.is_null (call $tab_get_str (ref.as_non_null (local.get $mt))
                                        (ref.as_non_null (global.get $g_mkey_newindex))))
      (then (call $tab_set_f_hash_str (local.get $t) (local.get $k) (local.get $full) (local.get $f))
            (return)))
    (call $lua_tabset (local.get $tv) (local.get $k) (call $make_float (local.get $f))))
  ;; `t[<int>] = <f64>` (the miss path of the inline write): array part (marker
  ;; + farr) when it lands there, else the hash part; a metatable defers to the
  ;; generic setter.
  (func $lua_tabset_ik_f (param $tv anyref) (param $k i64) (param $f f64)
    (local $t (ref $LuaTable))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $tv)))
      (then (call $throw_lit (i32.const 237) (i32.const 24))))   ;; "attempt to index a value"
    (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
    (if (i32.eqz (ref.is_null (struct.get $LuaTable $meta (local.get $t))))
      (then (call $lua_tabset (local.get $tv) (call $make_int (local.get $k)) (call $make_float (local.get $f)))
            (return)))
    (if (call $tab_set_arr (local.get $t) (local.get $k) (global.get $g_fmark))
      (then
        (array.set $FArr (call $farr_ensure (local.get $t))
          (i32.wrap_i64 (i64.sub (local.get $k) (i64.const 1))) (local.get $f))
        (return)))
    (call $tab_set_f_hash (local.get $t) (call $make_int (local.get $k)) (local.get $f)))

  ;; Cell loads: (tag, i64, f64, boxed) for a maybe-typed consumer — an
  ;; unboxed float slot yields tag 2 with no allocation; anything else is
  ;; classified by $unbox_num.
  (func $lua_index_sk_cell (param $tv anyref) (param $k (ref $LuaString)) (param $line i32)
                           (result i32 i64 f64 anyref)
    (local $t (ref $LuaTable)) (local $v anyref) (local $i i32) (local $full i32)
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then
        (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
        (local.set $full (struct.get $LuaString $hash (local.get $k)))
        (local.set $i (call $tab_find_str (local.get $t) (local.get $k) (local.get $full)))
        (if (i32.ge_s (local.get $i) (i32.const 0))
          (then
            (local.set $v (array.get $TArr (ref.as_non_null (struct.get $LuaTable $vals (local.get $t)))
                                           (local.get $i)))
            (if (ref.test (ref $FMark) (local.get $v))
              (then
                (i32.const 2) (i64.const 0)
                (array.get $FArr (ref.as_non_null (struct.get $LuaTable $fvals (local.get $t))) (local.get $i))
                (ref.null any)
                (return)))
            (if (i32.eqz (ref.is_null (local.get $v)))
              (then (call $unbox_num (local.get $v)) (local.get $v) (return)))))
        (local.set $v (call $tab_get_miss_str (local.get $t) (local.get $k) (local.get $full) (i32.const 64)))
        (call $unbox_num (local.get $v)) (local.get $v) (return)))
    (local.set $v (call $lua_index (local.get $tv) (local.get $k) (local.get $line)))
    (call $unbox_num (local.get $v)) (local.get $v))
  (func $lua_index_ik_cell (param $tv anyref) (param $k i64) (param $line i32) (result i32 i64 f64 anyref)
    (local $t (ref $LuaTable)) (local $v anyref) (local $i i32)
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then
        (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
        (if (i32.and (i64.ge_s (local.get $k) (i64.const 1))
                     (i64.le_s (local.get $k) (i64.extend_i32_s (struct.get $LuaTable $alen (local.get $t)))))
          (then
            (local.set $i (i32.wrap_i64 (i64.sub (local.get $k) (i64.const 1))))
            (local.set $v (array.get $TArr (ref.as_non_null (struct.get $LuaTable $arr (local.get $t))) (local.get $i)))
            (if (ref.test (ref $FMark) (local.get $v))
              (then
                (i32.const 2) (i64.const 0)
                (array.get $FArr (ref.as_non_null (struct.get $LuaTable $farr (local.get $t))) (local.get $i))
                (ref.null any)
                (return)))
            (if (i32.eqz (ref.is_null (local.get $v)))
              (then (call $unbox_num (local.get $v)) (local.get $v) (return)))))))
    (local.set $v (call $lua_index_ik_slow (local.get $tv) (local.get $k) (local.get $line)))
    (call $unbox_num (local.get $v)) (local.get $v))
  ;; The slow path of an inline `t[<int>]` cell read (src/codegen/arrays.c):
  ;; the codegen has already probed the array part.
  (func $lua_index_ik_cell_slow (param $tv anyref) (param $k i64) (param $line i32) (result i32 i64 f64 anyref)
    (local $v anyref)
    (local.set $v (call $lua_index_ik_slow (local.get $tv) (local.get $k) (local.get $line)))
    (call $unbox_num (local.get $v)) (local.get $v))
  (func $lua_index_mk_cell (param $tv anyref) (param $tag i32) (param $ki i64) (param $kf f64)
                           (param $kb anyref) (param $line i32) (result i32 i64 f64 anyref)
    (local $v anyref)
    (if (i32.eq (local.get $tag) (i32.const 1))
      (then (return_call $lua_index_ik_cell (local.get $tv) (local.get $ki) (local.get $line))))
    (local.set $v (call $lua_index (local.get $tv)
      (call $box_num (local.get $tag) (local.get $ki) (local.get $kf) (local.get $kb)) (local.get $line)))
    (call $unbox_num (local.get $v)) (local.get $v))

  ;; Maybe-typed key (docs/design/22): the cell's (tag, i64, f64, boxed) —
  ;; an int key takes the raw-i64 fast path, anything else boxes and goes
  ;; generic. Boxing only happens on the slow path.
  (func $lua_index_mk (param $tv anyref) (param $tag i32) (param $ki i64) (param $kf f64)
                      (param $kb anyref) (param $line i32) (result anyref)
    (if (i32.eq (local.get $tag) (i32.const 1))
      (then (return (call $lua_index_ik (local.get $tv) (local.get $ki) (local.get $line)))))
    (call $lua_index (local.get $tv)
      (call $box_num (local.get $tag) (local.get $ki) (local.get $kf) (local.get $kb))
      (local.get $line)))
  (func $lua_tabset_mk (param $tv anyref) (param $tag i32) (param $ki i64) (param $kf f64)
                       (param $kb anyref) (param $v anyref)
    (if (i32.eq (local.get $tag) (i32.const 1))
      (then (call $lua_tabset_ik (local.get $tv) (local.get $ki) (local.get $v)) (return)))
    (call $lua_tabset (local.get $tv)
      (call $box_num (local.get $tag) (local.get $ki) (local.get $kf) (local.get $kb))
      (local.get $v)))

  ;; `t[k]` read with an unboxed integer key (the int case of $lua_index_mk;
  ;; codegen probes the array part inline and calls $lua_index_ik_slow). A
  ;; value present in the array part returns directly, with no key boxing;
  ;; everything else takes $lua_index_ik_slow.
  (func $lua_index_ik (param $tv anyref) (param $k i64) (param $line i32) (result anyref)
    (local $t (ref $LuaTable)) (local $v anyref)
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then
        (local.set $t (ref.cast (ref $LuaTable) (local.get $tv)))
        (if (i32.and (i64.ge_s (local.get $k) (i64.const 1))
                     (i64.le_s (local.get $k) (i64.extend_i32_s (struct.get $LuaTable $alen (local.get $t)))))
          (then
            (local.set $v (call $tval
              (array.get $TArr (ref.as_non_null (struct.get $LuaTable $arr (local.get $t)))
                               (i32.wrap_i64 (i64.sub (local.get $k) (i64.const 1))))
              (struct.get $LuaTable $farr (local.get $t)) (i32.wrap_i64 (i64.sub (local.get $k) (i64.const 1)))))
            (if (i32.eqz (ref.is_null (local.get $v))) (then (return (local.get $v))))))))
    (return_call $lua_index_ik_slow (local.get $tv) (local.get $k) (local.get $line)))
  ;; The rest of `t[k]`: a hole or a key outside the array part goes through
  ;; $tab_get (hash part, then __index); a non-table receiver through
  ;; $lua_index (string library / error).
  (func $lua_index_ik_slow (param $tv anyref) (param $k i64) (param $line i32) (result anyref)
    (if (ref.test (ref $LuaTable) (local.get $tv))
      (then (return (call $tab_get (ref.cast (ref $LuaTable) (local.get $tv)) (call $make_int (local.get $k))))))
    (call $lua_index (local.get $tv) (call $make_int (local.get $k)) (local.get $line)))


  ;; `t[k] = v` with __newindex dispatch. Used by user-code assignments.
  ;; Table-constructor inserts go through bare \$tab_set since they target
  ;; freshly built tables with no metatable.
  ;;
  ;; Lua: if t[k] is already present, do a raw set (no metamethod). Otherwise,
  ;; if t has __newindex:
  ;;   - table form: do lua_tabset on that table (recurses, with cycle guard)
  ;;   - function form: call __newindex(t, k, v)
  ;; If __newindex is absent, do the raw set.
  (func $lua_tabset (param $v anyref) (param $k anyref) (param $val anyref)
    (local $t (ref $LuaTable)) (local $mt (ref null $LuaTable))
    (local $mm anyref) (local $depth i32) (local $cost_saved i32)
    (block $exit (loop $top
      ;; If $v isn't a table, fall through to the metamethod path on the
      ;; value's metatable (rare; objects with __index/__newindex but no
      ;; backing table). For now require a table.
      (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v)))
        (then (call $throw_lit (i32.const 237) (i32.const 24))))   ;; "attempt to index a value"
      (local.set $t (ref.cast (ref $LuaTable) (local.get $v)))
      ;; No metatable -> always a raw set (the common case; skips the presence
      ;; check entirely).
      (local.set $mt (struct.get $LuaTable $meta (local.get $t)))
      (if (ref.is_null (local.get $mt))
        (then (call $tab_set (local.get $t) (local.get $k) (local.get $val))
              (br $exit)))
      ;; Metatable present: __newindex only fires for an ABSENT key. Presence
      ;; must consider the array part too (tab_get_raw), not just the hash —
      ;; otherwise an array-part key would spuriously trigger __newindex.
      (if (i32.eqz (ref.is_null (call $tab_get_raw (local.get $t) (local.get $k))))
        (then (call $tab_set (local.get $t) (local.get $k) (local.get $val))
              (br $exit)))
      (local.set $mm (call $tab_get_str (ref.as_non_null (local.get $mt))
        (ref.as_non_null (global.get $g_mkey_newindex))))
      (if (ref.is_null (local.get $mm))
        (then (call $tab_set (local.get $t) (local.get $k) (local.get $val))
              (br $exit)))
      ;; Function form: call __newindex(t, k, val) and we're done.
      (if (ref.test (ref $LuaClosure) (local.get $mm))
        (then
          (drop (call $call_mm1 (local.get $mm) (local.get $v) (local.get $k) (local.get $val) (i32.const 3)))
          (br $exit)))
      ;; Table form: continue with $v = mm. Cycle cap matches __index.
      (local.set $v (local.get $mm))
      (local.set $depth (i32.add (local.get $depth) (i32.const 1)))
      (if (i32.gt_s (local.get $depth) (i32.const 200))
        (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 541) (i32.const 42)) (i32.const 0)))))
      (br $top))))
