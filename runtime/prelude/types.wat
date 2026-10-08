;; The value representation: every WasmGC type the runtime and the compiled
;; program share (strings, numbers, closures, tables and their shapes, the
;; inline caches, and the runtime's scratch structures).

  ;; --- value-rep types ---
  (type $LuaArr    (array (mut i8)))
  ;; $hash caches the FNV-1a hash of $bytes (0 = not yet computed; a computed
  ;; hash of 0 is stored as 1). Strings are immutable once visible to Lua, so the
  ;; cache never goes stale. Table lookups compare cached hashes before bytes,
  ;; and compile-time constants carry their hash from codegen.
  (type $LuaString (sub (struct (field $bytes (ref $LuaArr)) (field $hash (mut i32)))))
  (type $LuaFloat  (sub (struct (field $v f64))))
  (type $LuaInt    (sub (struct (field $v i64))))
  (type $LuaBool   (sub (struct (field $b i32))))
  ;; --- closure / function types (mutually recursive) ---
  (type $Box       (sub (struct (field $v (mut anyref)))))
  (type $ArgArr    (array (mut anyref)))
  (type $UpvalArr  (array (mut (ref $Box))))
  ;; Per-activation to-be-closed stack: $items holds the values bound to
  ;; <close> variables in declaration order; $len is the live count.
  (type $Tbc       (struct (field $items (mut (ref $ArgArr))) (field $len (mut i32))))
  ;; Capture buffer for Lua patterns. Two i32 cells per capture:
  ;;   [2*i]   = subject byte offset where capture i starts
  ;;   [2*i+1] = length sentinel:
  ;;               >= 0  closed substring capture, that many bytes
  ;;               -1    open substring capture (still on the parser stack)
  ;;               -2    position capture (cell [2*i] is the 0-based pos)
  (type $CapArr    (array (mut i32)))
  ;; Call-frame line stack. Indexed by $call_depth: entry [d] is the
  ;; source line where the function currently at depth d+1 was called
  ;; from. error(msg, level) reads [depth - level] to build the
  ;; "<src>:<line>: " prefix; debug.traceback walks the whole stack.
  (type $LineArr   (array (mut i32)))
  ;; Growable byte buffer used by string.gsub. Owns a backing $LuaArr
  ;; that doubles on overflow.
  (type $Builder   (struct (field $arr (mut (ref $LuaArr)))
                           (field $len (mut i32))))
  (rec
    (type $LuaClosure (sub (struct (field $code (ref $LuaFn))
                                   (field $upvals (ref $UpvalArr))
                                   ;; estimated wasm frame bytes of $code, for
                                   ;; the stack-budget guard in $push_call_frame
                                   (field $weight i32)
                                   ;; single-result entry: see $LuaFn1
                                   (field $fast (ref $LuaFn1)))))
    (type $LuaFn (func (param (ref $LuaClosure))
                       (param (ref $ArgArr))
                       (result (ref $ArgArr))))
    ;; The fast entry for a call that wants one result and passes at most
    ;; four arguments: arguments in a0..a3 (unused ones nil) plus their
    ;; count, the first result returned directly — no $ArgArr either side.
    ;; A user function with <= 4 parameters gets its own body for it
    ;; ($user_N_f); everything else (builtins, wider functions) gets
    ;; $fast_adapter, which packs the arguments for $code.
    (type $LuaFn1 (func (param (ref $LuaClosure))
                        (param anyref anyref anyref anyref) (param i32)
                        (result anyref))))
  ;; --- table type ---
  ;; The hash part keeps its keys in insertion order (so iteration stays
  ;; simple and `next` is well-defined) in a $Shape, and the values at the
  ;; same positions in the table's $vals. Lookups go through the shape's
  ;; open-addressing hash index $idx, which stores (key_position + 1) for each
  ;; populated slot; 0 means empty, -1 a tombstone. The index is power-of-two
  ;; sized and probed linearly (the load factor cap keeps chains short).
  ;; Tables built by adding the same string keys in the same order share one
  ;; immutable shape, reached through cached transitions; a table that turns
  ;; into a dictionary gets a private shape it mutates in place
  ;; (docs/design/23-table-shapes.md).
  (type $TArr (array (mut anyref)))
  (type $IArr (array (mut i32)))
  (rec
    (type $Shape (struct
      (field $keys (mut (ref $TArr)))   ;; keys[0..n) in insertion order
      (field $idx  (mut (ref $IArr)))
      (field $mask (mut i32))
      (field $n    (mut i32))
      (field $used (mut i32))           ;; occupied index slots: keys + tombstones
      ;; transition cache (shared shapes): key -> child shape, direct-mapped
      ;; by the key's hash, matched by key identity
      (field $tkeys (mut (ref null $TArr)))
      (field $tkids (mut (ref null $ShapeArr)))))
    (type $ShapeArr (array (mut (ref null $Shape)))))
  ;; Unboxed float storage (docs/design/22, "typed table storage"): a table
  ;; value slot holding $g_fmark means the real value is the f64 at the same
  ;; index of the parallel $fvals / $farr array. Readers translate; the
  ;; unboxed writers and cell readers below never allocate a $LuaFloat.
  (type $FArr (array (mut f64)))
  (type $FMark (struct))
  (rec
    (type $LuaTable (sub (struct
      (field $shape (mut (ref $Shape)))     ;; the hash part's key layout
      (field $vals (mut (ref null $TArr)))  ;; hash values by key position
      (field $own  (mut i32))               ;; 1: $shape is this table's alone
      (field $meta (mut (ref null $LuaTable)))
      (field $id   i32)         ;; unique identity for hashing table keys
      ;; Array part: integer keys 1..$alen in $arr[0..alen-1]. Slots may be nil
      ;; (holes) but the last one never is, so $alen is a border; a part that
      ;; is mostly holes moves to the hash when it would grow ($tab_set_arr).
      ;; Gives O(1) integer access; everything else lives in the hash.
      (field $arr  (mut (ref null $TArr)))
      (field $alen (mut i32))
      ;; parallel f64 storage for slots marked $g_fmark (lazily allocated)
      (field $fvals (mut (ref null $FArr)))
      (field $farr  (mut (ref null $FArr)))))))

  ;; Inline caches for constant-key access sites (docs/design/23): codegen
  ;; gives every `t.name` read/write site an $IC and every `obj:m(...)` site a
  ;; $MIC, held in an immutable module global. $pos is valid for $shape: a
  ;; shape's key positions never change (a compaction installs a new $Shape),
  ;; so "table.shape == cached shape" proves the key sits at $pos.
  (type $IC (struct (field $shape (mut (ref null $Shape))) (field $pos (mut i32))))
  (type $MIC (struct
    (field $s1 (mut (ref null $Shape)))      ;; a receiver shape lacking the key (shared)
    (field $ms (mut (ref null $Shape)))      ;; the metatable's shape ...
    (field $mp (mut i32))                    ;; ... and "__index"'s position in it
    (field $c  (mut (ref null $LuaTable)))   ;; the __index table
    (field $cs (mut (ref null $Shape)))      ;; its shape ...
    (field $cp (mut i32))))                  ;; ... and the method's position in it
