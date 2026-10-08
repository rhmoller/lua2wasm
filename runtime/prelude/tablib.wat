;; The table library: insert, remove, concat, sort, create, move, pack,
;; unpack.

  ;; table.insert(t, v)         -> append at #t+1
  ;; table.insert(t, pos, v)    -> shift t[pos..#t] up, t[pos] = v
  (func $builtin_table_insert (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $n i32) (local $pos i32) (local $v anyref)
    (local $i i32) (local $alen i32) (local $arr (ref null $TArr))
    (local.set $t (call $arg_table (call $args_at (local.get $args) (i32.const 0))))
    (local.set $n (call $tab_len (local.get $t)))
    (if (i32.eq (array.len (local.get $args)) (i32.const 2))
      (then
        (local.set $v (call $args_at (local.get $args) (i32.const 1)))
        (call $tab_set (local.get $t) (ref.i31 (i32.add (local.get $n) (i32.const 1))) (local.get $v))
        (return (global.get $g_empty_args))))
    ;; Only the 2- and 3-argument forms exist (the 1-arg/4+-arg cases used to
    ;; trap or silently drop arguments).
    (if (i32.ne (array.len (local.get $args)) (i32.const 3))
      (then (call $throw_lit (i32.const 925) (i32.const 25))))   ;; "wrong number of arguments"
    ;; 3-arg form: position must be in [1, #t+1].
    (local.set $pos (i32.wrap_i64 (call $as_int_co (call $args_at (local.get $args) (i32.const 1)))))
    (if (i32.or (i32.lt_s (local.get $pos) (i32.const 1))
                (i32.gt_s (local.get $pos) (i32.add (local.get $n) (i32.const 1))))
      (then (call $throw_lit (i32.const 837) (i32.const 22))))   ;; "position out of bounds"
    (local.set $v (call $args_at (local.get $args) (i32.const 2)))
    ;; Fast path: when the sequence is exactly the array part (no metatable,
    ;; n == $alen, and the value is non-nil so the last slot stays non-nil)
    ;; the whole shift is one memmove on $arr (holes move with it, as the
    ;; element-wise loop would move nils). array.copy handles the
    ;; overlapping forward shift like memmove. Behaviour is identical to the
    ;; loop below, which here would be pure raw array reads/writes anyway.
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    (if (i32.and (i32.and
            (ref.is_null (struct.get $LuaTable $meta (local.get $t)))
            (i32.eq (local.get $n) (local.get $alen)))
            (i32.eqz (ref.is_null (local.get $v))))
      (then
        (call $arr_ensure (local.get $t) (i32.add (local.get $alen) (i32.const 1)))
        (local.set $arr (struct.get $LuaTable $arr (local.get $t)))
        (array.copy $TArr $TArr
          (ref.as_non_null (local.get $arr)) (local.get $pos)
          (ref.as_non_null (local.get $arr)) (i32.sub (local.get $pos) (i32.const 1))
          (i32.add (i32.sub (local.get $n) (local.get $pos)) (i32.const 1)))
        (if (i32.eqz (ref.is_null (struct.get $LuaTable $farr (local.get $t))))
          (then (array.copy $FArr $FArr
            (ref.as_non_null (call $farr_ensure (local.get $t))) (local.get $pos)
            (ref.as_non_null (struct.get $LuaTable $farr (local.get $t))) (i32.sub (local.get $pos) (i32.const 1))
            (i32.add (i32.sub (local.get $n) (local.get $pos)) (i32.const 1)))))
        (array.set $TArr (ref.as_non_null (local.get $arr))
          (i32.sub (local.get $pos) (i32.const 1)) (local.get $v))
        (struct.set $LuaTable $alen (local.get $t) (i32.add (local.get $alen) (i32.const 1)))
        (return (global.get $g_empty_args))))
    ;; shift elements pos..n up by 1
    (local.set $i (local.get $n))
    (block $done (loop $lp
      (br_if $done (i32.lt_s (local.get $i) (local.get $pos)))
      (call $tab_set (local.get $t)
        (ref.i31 (i32.add (local.get $i) (i32.const 1)))
        (call $tab_get (local.get $t) (ref.i31 (local.get $i))))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $tab_set (local.get $t) (ref.i31 (local.get $pos)) (local.get $v))
    (global.get $g_empty_args))

  ;; table.remove(t [, pos])    -> default pos = #t; returns removed value
  (func $builtin_table_remove (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $n i32) (local $pos i32)
    (local $removed anyref) (local $i i32) (local $alen i32) (local $arr (ref null $TArr))
    (local.set $t (call $arg_table (call $args_at (local.get $args) (i32.const 0))))
    (local.set $n (call $tab_len (local.get $t)))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (local.set $pos
        (i32.wrap_i64 (call $as_int_co (call $args_at (local.get $args) (i32.const 1))))))
      (else (local.set $pos (local.get $n))))
    ;; When an explicit pos differs from #t, it must be in [1, #t+1]. (pos==#t
    ;; — including the empty-table default 0 — is always allowed.)
    (if (i32.ne (local.get $pos) (local.get $n))
      (then (if (i32.or (i32.lt_s (local.get $pos) (i32.const 1))
                        (i32.gt_s (local.get $pos) (i32.add (local.get $n) (i32.const 1))))
        (then (call $throw_lit (i32.const 837) (i32.const 22))))))   ;; "position out of bounds"
    ;; Fast path: the sequence is exactly the array part (no metatable,
    ;; n == $alen) with the removal point inside it. The shift-down is one
    ;; memmove on $arr, then we shrink the part (and trim any holes that end
    ;; up last). Identical to the loop below, which here would be pure raw
    ;; array reads/writes.
    (local.set $alen (struct.get $LuaTable $alen (local.get $t)))
    (if (i32.and (i32.and
            (ref.is_null (struct.get $LuaTable $meta (local.get $t)))
            (i32.eq (local.get $n) (local.get $alen)))
            (i32.and (i32.ge_s (local.get $pos) (i32.const 1))
                     (i32.le_s (local.get $pos) (local.get $n))))
      (then
        (local.set $arr (struct.get $LuaTable $arr (local.get $t)))
        (local.set $removed (call $tval (array.get $TArr (ref.as_non_null (local.get $arr))
          (i32.sub (local.get $pos) (i32.const 1)))
          (struct.get $LuaTable $farr (local.get $t)) (i32.sub (local.get $pos) (i32.const 1))))
        (array.copy $TArr $TArr
          (ref.as_non_null (local.get $arr)) (i32.sub (local.get $pos) (i32.const 1))
          (ref.as_non_null (local.get $arr)) (local.get $pos)
          (i32.sub (local.get $n) (local.get $pos)))
        (if (i32.eqz (ref.is_null (struct.get $LuaTable $farr (local.get $t))))
          (then (array.copy $FArr $FArr
            (ref.as_non_null (struct.get $LuaTable $farr (local.get $t))) (i32.sub (local.get $pos) (i32.const 1))
            (ref.as_non_null (struct.get $LuaTable $farr (local.get $t))) (local.get $pos)
            (i32.sub (local.get $n) (local.get $pos)))))
        (array.set $TArr (ref.as_non_null (local.get $arr))
          (i32.sub (local.get $n) (i32.const 1)) (ref.null any))
        (struct.set $LuaTable $alen (local.get $t) (i32.sub (local.get $alen) (i32.const 1)))
        (call $arr_trim (local.get $t))
        (return (array.new_fixed $ArgArr 1 (local.get $removed)))))
    (local.set $removed (call $tab_get (local.get $t) (ref.i31 (local.get $pos))))
    ;; shift elements pos+1..n down by 1, then clear the vacated slot
    (local.set $i (local.get $pos))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (call $tab_set (local.get $t) (ref.i31 (local.get $i))
        (call $tab_get (local.get $t) (ref.i31 (i32.add (local.get $i) (i32.const 1)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (call $tab_set (local.get $t) (ref.i31 (local.get $i)) (ref.null any))
    (array.new_fixed $ArgArr 1 (local.get $removed)))

  ;; table.concat(t [, sep])    -> string concatenation of t[1..#t]
  ;; table.concat(t [, sep [, i [, j]]]) -> t[i] .. sep .. ... .. t[j].
  ;; Defaults: sep = "", i = 1, j = #t. An empty range (i > j) yields "".
  (func $builtin_table_concat (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $sep anyref) (local $acc anyref)
    (local $i i32) (local $j i32) (local $k i32) (local $nargs i32)
    (local $elem anyref)
    (local $bld (ref $Builder)) (local $sepb (ref $LuaArr)) (local $eb (ref $LuaArr))
    (local.set $t (call $arg_table (call $args_at (local.get $args) (i32.const 0))))
    (local.set $nargs (array.len (local.get $args)))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $sep (call $args_at (local.get $args) (i32.const 1))))
      (else (local.set $sep (ref.as_non_null (global.get $g_empty_str)))))
    (local.set $i (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $i (i32.wrap_i64
              (call $as_int_co (call $args_at (local.get $args) (i32.const 2)))))))
    (local.set $j (call $tab_len (local.get $t)))
    (if (i32.gt_u (local.get $nargs) (i32.const 3))
      (then (local.set $j (i32.wrap_i64
              (call $as_int_co (call $args_at (local.get $args) (i32.const 3)))))))
    (if (i32.gt_s (local.get $i) (local.get $j))
      (then (return (array.new_fixed $ArgArr 1 (ref.as_non_null (global.get $g_empty_str))))))
    ;; Reference table.concat accepts only strings and numbers per element
    ;; (it does NOT tostring tables/booleans); anything else is a catchable
    ;; "invalid value ... for 'concat'" error. Reads still go through $tab_get
    ;; (so __index is honoured, like reference Lua), but the pieces are
    ;; accumulated in a single $Builder (O(total) bytes) instead of chaining
    ;; $lua_concat, which reallocates the whole prefix per element -> O(n^2).
    (local.set $sepb (struct.get $LuaString $bytes (call $lua_tostring (local.get $sep))))
    (local.set $bld (call $builder_new))
    (local.set $acc (call $tab_get (local.get $t) (ref.i31 (local.get $i))))
    (if (i32.eqz (call $is_concatable (local.get $acc)))
      (then (call $throw_lit (i32.const 785) (i32.const 35))))
    (local.set $eb (struct.get $LuaString $bytes (call $lua_tostring (local.get $acc))))
    (call $builder_append (local.get $bld) (local.get $eb)
      (i32.const 0) (array.len (local.get $eb)))
    (local.set $k (i32.add (local.get $i) (i32.const 1)))
    (block $done (loop $lp
      (br_if $done (i32.gt_s (local.get $k) (local.get $j)))
      (local.set $elem (call $tab_get (local.get $t) (ref.i31 (local.get $k))))
      (if (i32.eqz (call $is_concatable (local.get $elem)))
        (then (call $throw_lit (i32.const 785) (i32.const 35))))
      ;; Guard an i32 byte-length overflow before the builder's array.new can
      ;; trap, matching $lua_concat's catchable "too large".
      (local.set $eb (struct.get $LuaString $bytes (call $lua_tostring (local.get $elem))))
      (if (i32.lt_s
            (i32.add (struct.get $Builder $len (local.get $bld))
              (i32.add (array.len (local.get $sepb)) (array.len (local.get $eb))))
            (i32.const 0))
        (then (call $throw_lit (i32.const 297) (i32.const 9))))    ;; "too large"
      (call $builder_append (local.get $bld) (local.get $sepb)
        (i32.const 0) (array.len (local.get $sepb)))
      (call $builder_append (local.get $bld) (local.get $eb)
        (i32.const 0) (array.len (local.get $eb)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $lp)))
    (array.new_fixed $ArgArr 1 (call $builder_finish (local.get $bld))))

  ;; table.unpack(t [, i [, j]]) -> t[i], t[i+1], ..., t[j].
  ;; Defaults: i = 1, j = #t. Returns no values when j < i.
  ;; --- table.sort ---
  ;;
  ;; Comparator wrapper: if $cmp is null, use the built-in `<`; otherwise
  ;; invoke the user closure with (a, b) and take the truthiness of its
  ;; first return.
  (func $cmp_lt (param $cmp (ref null $LuaClosure))
                (param $a anyref) (param $b anyref) (result i32)
    (if (result i32) (ref.is_null (local.get $cmp))
      (then (call $lua_lt_raw (local.get $a) (local.get $b)))
      (else (call $lua_truthy
        (call $call_mm1 (local.get $cmp) (local.get $a) (local.get $b) (ref.null any) (i32.const 2))))))

  ;; Hoare partition of a[lo..up] around the pivot at a[up-1] (placed there by
  ;; $qsort's median-of-3). Returns the pivot's final index. Faithful to
  ;; reference Lua's `partition`: the ++i / --j scans rely on a[lo] <= pivot <=
  ;; a[up] as sentinels, and the in-bounds checks (i hits up-1 still < pivot, or
  ;; j crosses i still > pivot) are exactly how Lua detects an inconsistent order
  ;; function — it raises "invalid order function for sorting".
  (func $partition (param $t (ref $LuaTable)) (param $lo i32) (param $up i32)
                   (param $cmp (ref null $LuaClosure)) (result i32)
    (local $i i32) (local $j i32) (local $upm1 i32)
    (local $pivot anyref) (local $ai anyref) (local $aj anyref)
    (local.set $upm1 (i32.sub (local.get $up) (i32.const 1)))
    (local.set $pivot (call $tab_get_arr_idx (local.get $t) (local.get $upm1)))
    (local.set $i (local.get $lo))
    (local.set $j (local.get $upm1))
    (block $done (loop $main
      ;; ++i while a[i] < pivot
      (block $iscan (loop $iloop
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $ai (call $tab_get_arr_idx (local.get $t) (local.get $i)))
        (br_if $iscan (i32.eqz
          (call $cmp_lt (local.get $cmp) (local.get $ai) (local.get $pivot))))
        (if (i32.eq (local.get $i) (local.get $upm1))
          (then (call $throw_lit (i32.const 1115) (i32.const 34))))
        (br $iloop)))
      ;; --j while pivot < a[j]
      (block $jscan (loop $jloop
        (local.set $j (i32.sub (local.get $j) (i32.const 1)))
        (local.set $aj (call $tab_get_arr_idx (local.get $t) (local.get $j)))
        (br_if $jscan (i32.eqz
          (call $cmp_lt (local.get $cmp) (local.get $pivot) (local.get $aj))))
        (if (i32.lt_s (local.get $j) (local.get $i))
          (then (call $throw_lit (i32.const 1115) (i32.const 34))))
        (br $jloop)))
      ;; i < j ? swap a[i],a[j] and continue : stop
      (br_if $done (i32.ge_s (local.get $i) (local.get $j)))
      (call $tab_set_arr_idx (local.get $t) (local.get $i) (local.get $aj))
      (call $tab_set_arr_idx (local.get $t) (local.get $j) (local.get $ai))
      (br $main)))
    ;; move the pivot into place: swap a[i] and a[up-1]
    (call $tab_set_arr_idx (local.get $t) (local.get $upm1)
      (call $tab_get_arr_idx (local.get $t) (local.get $i)))
    (call $tab_set_arr_idx (local.get $t) (local.get $i) (local.get $pivot))
    (local.get $i))

  ;; In-place quicksort of a[lo..hi] (reference Lua's `auxsort`): median-of-3 of
  ;; (lo, mid, up) — which also sorts the 2- and 3-element base cases directly —
  ;; then partition and "recurse the smaller side, iterate the larger" for
  ;; O(log n) stack depth. No randomized pivot (Lua only randomizes intervals
  ;; >= 100, where its order is non-deterministic anyway).
  (func $qsort (param $t (ref $LuaTable))
               (param $lo i32) (param $hi i32)
               (param $cmp (ref null $LuaClosure))
    (local $up i32) (local $p i32) (local $pi i32)
    (local $alo anyref) (local $aup anyref) (local $ap anyref)
    (local.set $up (local.get $hi))
    (block $exit (loop $top
      (br_if $exit (i32.ge_s (local.get $lo) (local.get $up)))
      ;; sort a[lo], a[up]
      (local.set $alo (call $tab_get_arr_idx (local.get $t) (local.get $lo)))
      (local.set $aup (call $tab_get_arr_idx (local.get $t) (local.get $up)))
      (if (call $cmp_lt (local.get $cmp) (local.get $aup) (local.get $alo))
        (then
          (call $tab_set_arr_idx (local.get $t) (local.get $lo) (local.get $aup))
          (call $tab_set_arr_idx (local.get $t) (local.get $up) (local.get $alo))))
      ;; 2 elements: sorted
      (br_if $exit (i32.eq (i32.sub (local.get $up) (local.get $lo)) (i32.const 1)))
      ;; p = floor((lo+up)/2); sort a[p] into [a[lo], a[up]]
      (local.set $p (i32.shr_s (i32.add (local.get $lo) (local.get $up)) (i32.const 1)))
      (local.set $ap (call $tab_get_arr_idx (local.get $t) (local.get $p)))
      (local.set $alo (call $tab_get_arr_idx (local.get $t) (local.get $lo)))
      (if (call $cmp_lt (local.get $cmp) (local.get $ap) (local.get $alo))
        (then
          (call $tab_set_arr_idx (local.get $t) (local.get $p) (local.get $alo))
          (call $tab_set_arr_idx (local.get $t) (local.get $lo) (local.get $ap)))
        (else
          (local.set $aup (call $tab_get_arr_idx (local.get $t) (local.get $up)))
          (if (call $cmp_lt (local.get $cmp) (local.get $aup) (local.get $ap))
            (then
              (call $tab_set_arr_idx (local.get $t) (local.get $p) (local.get $aup))
              (call $tab_set_arr_idx (local.get $t) (local.get $up) (local.get $ap))))))
      ;; 3 elements: sorted
      (br_if $exit (i32.eq (i32.sub (local.get $up) (local.get $lo)) (i32.const 2)))
      ;; move pivot a[p] to a[up-1]
      (local.set $ap (call $tab_get_arr_idx (local.get $t) (local.get $p)))
      (call $tab_set_arr_idx (local.get $t) (local.get $p)
        (call $tab_get_arr_idx (local.get $t) (i32.sub (local.get $up) (i32.const 1))))
      (call $tab_set_arr_idx (local.get $t) (i32.sub (local.get $up) (i32.const 1))
        (local.get $ap))
      (local.set $pi (call $partition (local.get $t) (local.get $lo)
                       (local.get $up) (local.get $cmp)))
      ;; recurse the smaller side, iterate the larger
      (if (i32.lt_s (i32.sub (local.get $pi) (local.get $lo))
                    (i32.sub (local.get $up) (local.get $pi)))
        (then
          (call $qsort (local.get $t) (local.get $lo)
                       (i32.sub (local.get $pi) (i32.const 1)) (local.get $cmp))
          (local.set $lo (i32.add (local.get $pi) (i32.const 1))))
        (else
          (call $qsort (local.get $t) (i32.add (local.get $pi) (i32.const 1))
                       (local.get $up) (local.get $cmp))
          (local.set $up (i32.sub (local.get $pi) (i32.const 1)))))
      (br $top))))

  ;; table.sort(t [, cmp]) — in-place sort of t[1..#t].
  (func $builtin_table_sort (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $cmp (ref null $LuaClosure)) (local $n i32)
    (local $cmparg anyref)
    (local.set $t (call $arg_table (call $args_at (local.get $args) (i32.const 0))))
    ;; A 2nd argument, when present and non-nil, must be a function — check it
    ;; first so a wrong type is a catchable "function expected" error rather
    ;; than an uncatchable ref.cast trap. nil leaves $cmp null (default order).
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then
        (local.set $cmparg (call $args_at (local.get $args) (i32.const 1)))
        (if (i32.eqz (ref.is_null (local.get $cmparg)))
          (then
            (if (i32.eqz (ref.test (ref $LuaClosure) (local.get $cmparg)))
              (then (call $throw_lit (i32.const 1042) (i32.const 17))))   ;; "function expected"
            (local.set $cmp (ref.cast (ref $LuaClosure) (local.get $cmparg)))))))
    (local.set $n (call $tab_len (local.get $t)))
    (if (i32.gt_s (local.get $n) (i32.const 1))
      (then (call $qsort (local.get $t) (i32.const 1) (local.get $n) (local.get $cmp))))
    (global.get $g_empty_args))

  ;; table.create(nseq [, nrec]): allocates a table with pre-sized
  ;; storage. The table starts empty (n=0); the pre-sizing means
  ;; subsequent inserts up to nseq+nrec won't trigger a grow.
  ;; Our table representation has one combined keys/vals array, so we
  ;; treat both hints as a single capacity request.
  (func $builtin_table_create (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $nseq i32) (local $nrec i32) (local $cap i32)
    (local.set $t (call $tab_new))
    (local.set $nseq (i32.wrap_i64 (call $as_int_co (call $args_at (local.get $args) (i32.const 0)))))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 1))
      (then (local.set $nrec
              (i32.wrap_i64 (call $as_int_co (call $args_at (local.get $args) (i32.const 1)))))))
    (local.set $cap (i32.add (local.get $nseq) (local.get $nrec)))
    (if (i32.gt_s (local.get $nseq) (i32.const 0))
      (then (call $arr_ensure (local.get $t) (local.get $nseq))))
    (if (i32.gt_s (local.get $nrec) (i32.const 0))
      (then (call $tab_reserve_hash (local.get $t) (local.get $nrec))))
    (array.new_fixed $ArgArr 1 (local.get $t)))

  ;; table.move(a1, f, e, t [, a2]): copy a1[f..e] to (a2 or a1)[t..].
  ;; Returns the destination table. Handles overlap (a1 == a2 with
  ;; t in [f, e]) by choosing iteration direction.
  ;; If f > e, nothing to copy; still returns the destination.
  (func $builtin_table_move (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $a1 (ref $LuaTable)) (local $a2 (ref $LuaTable))
    (local $f i32) (local $e i32) (local $t i32)
    (local $n i32) (local $i i32) (local $v anyref)
    (local $alen1 i32) (local $alen2 i32)
    (local.set $a1 (call $arg_table (call $args_at (local.get $args) (i32.const 0))))
    (local.set $f  (i32.wrap_i64 (call $as_int_co (call $args_at (local.get $args) (i32.const 1)))))
    (local.set $e  (i32.wrap_i64 (call $as_int_co (call $args_at (local.get $args) (i32.const 2)))))
    (local.set $t  (i32.wrap_i64 (call $as_int_co (call $args_at (local.get $args) (i32.const 3)))))
    ;; optional 5th arg: destination table; defaults to a1.
    (local.set $a2 (local.get $a1))
    (if (i32.gt_u (array.len (local.get $args)) (i32.const 4))
      (then (local.set $a2
              (call $arg_table (call $args_at (local.get $args) (i32.const 4))))))
    ;; nothing to do if range is empty (f > e).
    (if (i32.le_s (local.get $f) (local.get $e))
      (then
        (local.set $n (i32.add (i32.sub (local.get $e) (local.get $f)) (i32.const 1)))
        ;; Fast path: source range [f,e] sits entirely in a1's array part and
        ;; the destination range [t, t+n-1] sits entirely in a2's array part
        ;; (an in-place overwrite, no growth; holes copy as nils). One array.copy then
        ;; handles the bulk move; array.copy is memmove-correct for the
        ;; same-array overlapping case, so no direction analysis is needed.
        (local.set $alen1 (struct.get $LuaTable $alen (local.get $a1)))
        (local.set $alen2 (struct.get $LuaTable $alen (local.get $a2)))
        (if (i32.and (i32.and
                (i32.and (i32.ge_s (local.get $f) (i32.const 1))
                         (i32.le_s (local.get $e) (local.get $alen1)))
                (i32.and (i32.ge_s (local.get $t) (i32.const 1))
                         (i32.le_s (i32.add (local.get $t) (i32.sub (local.get $n) (i32.const 1)))
                                   (local.get $alen2))))
                (i32.and
                  (i32.eqz (i32.and (ref.eq (local.get $a1) (local.get $a2))
                                    (i32.eq (local.get $t) (local.get $f))))
                  (ref.is_null (struct.get $LuaTable $farr (local.get $a1)))))
          (then
            (array.copy $TArr $TArr
              (ref.as_non_null (struct.get $LuaTable $arr (local.get $a2)))
              (i32.sub (local.get $t) (i32.const 1))
              (ref.as_non_null (struct.get $LuaTable $arr (local.get $a1)))
              (i32.sub (local.get $f) (i32.const 1))
              (local.get $n))
            ;; holes copied onto the destination's end must not end it
            (call $arr_trim (local.get $a2))
            (return (array.new_fixed $ArgArr 1 (local.get $a2)))))
        ;; If dst overlaps src and t > f, iterate backward to avoid clobbering.
        ;; Backward iteration: i = n-1 ..= 0, dst[t+i] = src[f+i].
        ;; Forward iteration:  i = 0 ..< n.
        (if (i32.and
              (ref.eq (local.get $a1) (local.get $a2))
              (i32.gt_s (local.get $t) (local.get $f)))
          (then
            (local.set $i (i32.sub (local.get $n) (i32.const 1)))
            (block $done (loop $lp
              (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
              (local.set $v (call $tab_get_raw (local.get $a1)
                              (ref.i31 (i32.add (local.get $f) (local.get $i)))))
              (call $tab_set (local.get $a2)
                (ref.i31 (i32.add (local.get $t) (local.get $i)))
                (local.get $v))
              (local.set $i (i32.sub (local.get $i) (i32.const 1)))
              (br $lp))))
          (else
            (local.set $i (i32.const 0))
            (block $done2 (loop $lp2
              (br_if $done2 (i32.ge_s (local.get $i) (local.get $n)))
              (local.set $v (call $tab_get_raw (local.get $a1)
                              (ref.i31 (i32.add (local.get $f) (local.get $i)))))
              (call $tab_set (local.get $a2)
                (ref.i31 (i32.add (local.get $t) (local.get $i)))
                (local.get $v))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $lp2)))))))
    (array.new_fixed $ArgArr 1 (local.get $a2)))

  ;; table.pack(...): returns { [1] = a1, ..., [n] = an, n = nargs }.
  (func $builtin_table_pack (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $n i32) (local $i i32)
    (local $nkey (ref $LuaString))
    (local.set $t (call $tab_new))
    (local.set $n (array.len (local.get $args)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (call $tab_set (local.get $t)
        (ref.i31 (i32.add (local.get $i) (i32.const 1)))
        (call $args_at (local.get $args) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    ;; n = nargs   (key is the single-byte string "n", ASCII 110)
    (local.set $nkey (struct.new $LuaString
      (array.new_fixed $LuaArr 1 (i32.const 110)) (i32.const 0)))
    (call $tab_set (local.get $t) (local.get $nkey)
      (call $make_int (i64.extend_i32_s (local.get $n))))
    (array.new_fixed $ArgArr 1 (local.get $t)))

  (func $builtin_table_unpack (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $t (ref $LuaTable)) (local $i i32) (local $j i32) (local $nargs i32)
    (local $count i32) (local $k i32) (local $out (ref $ArgArr))
    (local.set $t (call $arg_table (call $args_at (local.get $args) (i32.const 0))))
    (local.set $nargs (array.len (local.get $args)))
    (local.set $i (i32.const 1))
    (if (i32.gt_u (local.get $nargs) (i32.const 1))
      (then (local.set $i (i32.wrap_i64
              (call $as_int_co (call $args_at (local.get $args) (i32.const 1)))))))
    (if (i32.gt_u (local.get $nargs) (i32.const 2))
      (then (local.set $j (i32.wrap_i64
              (call $as_int_co (call $args_at (local.get $args) (i32.const 2))))))
      (else (local.set $j (call $tab_len (local.get $t)))))
    (if (i32.lt_s (local.get $j) (local.get $i))
      (then (return (global.get $g_empty_args))))
    (local.set $count (i32.add (i32.sub (local.get $j) (local.get $i)) (i32.const 1)))
    (local.set $out (array.new $ArgArr (ref.null any) (local.get $count)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $k) (local.get $count)))
      (array.set $ArgArr (local.get $out) (local.get $k)
        (call $tab_get (local.get $t)
          (ref.i31 (i32.add (local.get $i) (local.get $k)))))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $lp)))
    (local.get $out))
