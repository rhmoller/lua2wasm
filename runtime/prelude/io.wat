;; The io library: io.read / io.write over the host's stdin and stdout, and
;; file handles over the host's file registry.

  ;; Default I/O files for bare io.write / io.read. Initialised to the stdout
  ;; and stdin handles in $stdlib_init; io.output(f) / io.input(f) reassign them.
  (global $g_io_output (mut (ref null $LuaTable)) (ref.null $LuaTable))
  (global $g_io_input  (mut (ref null $LuaTable)) (ref.null $LuaTable))

  ;; Invoke method $mkey on file handle $h with ($h, $args...) — i.e. as
  ;; `h:mkey(args...)`. Used to route bare io.write / io.read through the
  ;; current default output / input file so io.output(f) / io.input(f)
  ;; redirection takes effect.
  (func $io_via_default (param $h (ref $LuaTable)) (param $mkey (ref $LuaString))
                        (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $m anyref) (local $n i32) (local $na (ref $ArgArr))
    (local.set $m (call $tab_get_raw (local.get $h) (local.get $mkey)))
    (local.set $n (array.len (local.get $args)))
    (local.set $na (array.new $ArgArr (ref.null any) (i32.add (local.get $n) (i32.const 1))))
    (array.set $ArgArr (local.get $na) (i32.const 0) (local.get $h))
    (array.copy $ArgArr $ArgArr (local.get $na) (i32.const 1)
                                (local.get $args) (i32.const 0) (local.get $n))
    (call $lua_call (ref.cast (ref $LuaClosure) (local.get $m)) (local.get $na)))

  ;; io.write(...) — route through the default output file's :write method.
  (func $builtin_io_write (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $io_via_default (ref.as_non_null (global.get $g_io_output))
      (struct.new $LuaString (array.new_fixed $LuaArr 5
        (i32.const 119) (i32.const 114) (i32.const 105) (i32.const 116) (i32.const 101)) (i32.const 0))  ;; "write"
      (local.get $args)))

  ;; io.output([file]) — with a file-handle argument, make it the default
  ;; output; always return the (resulting) default output file.
  (func $builtin_io_output (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (if (i32.gt_s (array.len (local.get $args)) (i32.const 0))
      (then (if (ref.test (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0)))
        (then (global.set $g_io_output (ref.cast (ref $LuaTable)
          (call $args_at (local.get $args) (i32.const 0))))))))
    (array.new_fixed $ArgArr 1 (ref.as_non_null (global.get $g_io_output))))

  ;; io.input([file]) — same for the default input file.
  (func $builtin_io_input (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (if (i32.gt_s (array.len (local.get $args)) (i32.const 0))
      (then (if (ref.test (ref $LuaTable) (call $args_at (local.get $args) (i32.const 0)))
        (then (global.set $g_io_input (ref.cast (ref $LuaTable)
          (call $args_at (local.get $args) (i32.const 0))))))))
    (array.new_fixed $ArgArr 1 (ref.as_non_null (global.get $g_io_input))))

  ;; --- shared read core for io.read and file:read ---
  ;; A read source is identified by an i32 $fd: -1 means "the stdin host"
  ;; (host_read / host_read_num), >= 0 means an open file (fs_read /
  ;; fs_read_num). $fmt_buf is the shared landing buffer for both, capped
  ;; at 16384 bytes; "a" and large N-byte reads chunk through it so a file
  ;; bigger than the buffer doesn't overrun it. The 16384 here must match
  ;; LUA_FMT_BUF_CAP (src/codegen/internal.h; codegen_module allocates
  ;; $fmt_buf) and FMT_BUF_CAP (host-bindings.mjs).

  (func $read_src_bytes (param $fd i32) (param $mode i32) (param $count i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $fd) (i32.const 0))
      (then (call $host_read (local.get $mode) (local.get $count)))
      (else (call $host_fs_read (local.get $fd) (local.get $mode) (local.get $count)))))

  (func $read_src_num (param $fd i32) (result anyref)
    (if (result anyref) (i32.lt_s (local.get $fd) (i32.const 0))
      (then (call $host_read_num))
      (else (call $host_fs_read_num (local.get $fd)))))

  ;; "a": concat 16K chunks until the source reports nothing more (0).
  ;; Never returns null — empty string at EOF, per the spec.
  (func $read_all_str (param $fd i32) (result anyref)
    (local $acc anyref) (local $w i32)
    (local.set $acc (call $fmt_buf_to_str (i32.const 0)))   ;; ""
    (block $done (loop $lp
      (local.set $w (call $read_src_bytes (local.get $fd) (i32.const 2) (i32.const 0)))
      (br_if $done (i32.le_s (local.get $w) (i32.const 0)))
      (local.set $acc (call $lua_concat (local.get $acc)
                        (call $fmt_buf_to_str (local.get $w))))
      (br_if $done (i32.lt_s (local.get $w) (i32.const 16384)))
      (br $lp)))
    (local.get $acc))

  ;; Exactly $count bytes (or fewer at EOF), chunked through $fmt_buf.
  ;; Returns "" for count 0; null if count > 0 and the source is at EOF.
  (func $read_n_str (param $fd i32) (param $count i32) (result anyref)
    (local $acc anyref) (local $got i32) (local $chunk i32) (local $w i32)
    (local.set $acc (call $fmt_buf_to_str (i32.const 0)))   ;; ""
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $got) (local.get $count)))
      (local.set $chunk (i32.sub (local.get $count) (local.get $got)))
      (if (i32.gt_s (local.get $chunk) (i32.const 16384))
        (then (local.set $chunk (i32.const 16384))))
      (local.set $w (call $read_src_bytes (local.get $fd) (i32.const 3) (local.get $chunk)))
      (if (i32.lt_s (local.get $w) (i32.const 0))
        (then
          ;; EOF. Nothing read yet + count > 0 -> nil; otherwise the
          ;; partial accumulator (count 0 falls straight through to "").
          (if (i32.and (i32.eqz (local.get $got)) (i32.gt_s (local.get $count) (i32.const 0)))
            (then (return (ref.null any))))
          (br $done)))
      (local.set $acc (call $lua_concat (local.get $acc)
                        (call $fmt_buf_to_str (local.get $w))))
      (local.set $got (i32.add (local.get $got) (local.get $w)))
      (br_if $done (i32.lt_s (local.get $w) (local.get $chunk)))   ;; short read = EOF
      (br $lp)))
    (local.get $acc))

  ;; One result per format arg, reading from source $fd. $start skips a
  ;; leading $self for the file:read method form. With no format args,
  ;; behaves as a single "l".
  ;; Formats:
  ;;   "l"        line, no trailing \n (default)
  ;;   "L"        line, with trailing \n
  ;;   "a"        read all remaining (empty string at EOF, not nil)
  ;;   "n"        parse one number; nil if no number at the cursor
  ;;   integer N  read up to N bytes ("" at EOF for N == 0, else nil)
  ;; Older Lua's leading '*' in format strings (e.g. "*l") is tolerated.
  (func $io_read_impl (param $args (ref $ArgArr)) (param $start i32) (param $fd i32)
        (result (ref $ArgArr))
    (local $nargs i32) (local $neff i32) (local $i i32) (local $fmt anyref)
    (local $bytes (ref $LuaArr)) (local $blen i32) (local $b0 i32) (local $b1 i32)
    (local $mode i32) (local $count i32) (local $written i32)
    (local $out (ref $ArgArr)) (local $val anyref)
    (local.set $nargs (array.len (local.get $args)))
    (local.set $neff (i32.sub (local.get $nargs) (local.get $start)))
    ;; No formats: behave as a single "l".
    (if (i32.le_s (local.get $neff) (i32.const 0))
      (then
        (local.set $written (call $read_src_bytes (local.get $fd) (i32.const 0) (i32.const 0)))
        (if (i32.lt_s (local.get $written) (i32.const 0))
          (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
        (return (array.new_fixed $ArgArr 1
          (call $fmt_buf_to_str (local.get $written))))))
    (local.set $out (array.new $ArgArr (ref.null any) (local.get $neff)))
    (block $loopdone (loop $loop
      (br_if $loopdone (i32.ge_s (local.get $i) (local.get $neff)))
      (local.set $fmt (call $args_at (local.get $args)
                        (i32.add (local.get $start) (local.get $i))))
      (if (ref.test (ref $LuaString) (local.get $fmt))
        (then
          (local.set $bytes (struct.get $LuaString $bytes
            (ref.cast (ref $LuaString) (local.get $fmt))))
          (local.set $blen (array.len (local.get $bytes)))
          ;; Strip an optional leading '*' (legacy compat).
          (local.set $b0 (i32.const 0))
          (if (i32.and (i32.gt_s (local.get $blen) (i32.const 0))
                       (i32.eq (array.get_u $LuaArr (local.get $bytes) (i32.const 0))
                               (i32.const 42)))   ;; '*'
            (then (local.set $b0 (i32.const 1))))
          (if (i32.le_s (local.get $blen) (local.get $b0))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 416) (i32.const 14)) (i32.const 0)))))
          (local.set $b1 (array.get_u $LuaArr (local.get $bytes) (local.get $b0)))
          ;; map first non-'*' char to a mode
          (if (i32.eq (local.get $b1) (i32.const 108))         ;; 'l'
            (then (local.set $mode (i32.const 0)))
            (else (if (i32.eq (local.get $b1) (i32.const 76))  ;; 'L'
              (then (local.set $mode (i32.const 1)))
              (else (if (i32.eq (local.get $b1) (i32.const 97)) ;; 'a'
                (then (local.set $mode (i32.const 2)))
                (else (if (i32.eq (local.get $b1) (i32.const 110)) ;; 'n'
                  (then (local.set $mode (i32.const -1)))    ;; sentinel: number
                  (else (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 416) (i32.const 14)) (i32.const 0)))))))))))
          (if (i32.eq (local.get $mode) (i32.const -1))
            (then (local.set $val (call $read_src_num (local.get $fd))))
            (else (if (i32.eq (local.get $mode) (i32.const 2))
              (then (local.set $val (call $read_all_str (local.get $fd))))
              (else
                (local.set $written
                  (call $read_src_bytes (local.get $fd) (local.get $mode) (i32.const 0)))
                (if (i32.lt_s (local.get $written) (i32.const 0))
                  (then (local.set $val (ref.null any)))
                  (else (local.set $val (call $fmt_buf_to_str (local.get $written))))))))))
        (else
          ;; integer count — up to N bytes
          (local.set $count (i32.wrap_i64 (call $as_int (local.get $fmt))))
          (if (i32.lt_s (local.get $count) (i32.const 0))
            (then (throw $LuaError (struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const 416) (i32.const 14)) (i32.const 0)))))
          (local.set $val (call $read_n_str (local.get $fd) (local.get $count)))))
      (array.set $ArgArr (local.get $out) (local.get $i) (local.get $val))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $out))

  ;; io.read(...): read from stdin (fd -1), one result per format arg.
  ;; io.read(...) — route through the default input file's :read method.
  (func $builtin_io_read (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $io_via_default (ref.as_non_null (global.get $g_io_input))
      (struct.new $LuaString (array.new_fixed $LuaArr 4
        (i32.const 114) (i32.const 101) (i32.const 97) (i32.const 100)) (i32.const 0))  ;; "read"
      (local.get $args)))

  ;; File-handle methods over the host's stdio. The standard streams
  ;; don't have file objects to back them — the methods just route to
  ;; the right host import and return `self` so chains keep working.

  ;; Tostring + concat args[$start..]; returns null if no args remain.
  (func $io_concat_from (param $args (ref $ArgArr)) (param $start i32) (result anyref)
    (local $n i32) (local $i i32) (local $acc anyref)
    (local.set $n (array.len (local.get $args)))
    (if (i32.ge_s (local.get $start) (local.get $n))
      (then (return (ref.null any))))
    (local.set $acc (call $lua_tostring
      (call $args_at (local.get $args) (local.get $start))))
    (local.set $i (i32.add (local.get $start) (i32.const 1)))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $acc (call $lua_concat (local.get $acc)
        (call $lua_tostring (call $args_at (local.get $args) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $acc))

  (func $io_handle_write (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $acc anyref)
    (local.set $acc (call $io_concat_from (local.get $args) (i32.const 1)))
    (if (i32.eqz (ref.is_null (local.get $acc)))
      (then (call $host_write_raw (local.get $acc))))
    (array.new_fixed $ArgArr 1
      (call $args_at (local.get $args) (i32.const 0))))

  (func $io_handle_err_write (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $acc anyref)
    (local.set $acc (call $io_concat_from (local.get $args) (i32.const 1)))
    (if (i32.eqz (ref.is_null (local.get $acc)))
      (then (call $host_write_err (local.get $acc))))
    (array.new_fixed $ArgArr 1
      (call $args_at (local.get $args) (i32.const 0))))

  ;; file:read(...) on the stdin handle — drop the leading $self and read
  ;; from the stdin source (fd -1).
  (func $io_handle_read (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $io_read_impl (local.get $args) (i32.const 1) (i32.const -1)))

  ;; No-op stub returned by file:close / :flush / :seek on the standard
  ;; streams. Returns the file itself so chains keep working.
  (func $io_handle_noop (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (if (i32.eqz (array.len (local.get $args)))
      (then (return (global.get $g_empty_args))))
    (array.new_fixed $ArgArr 1
      (call $args_at (local.get $args) (i32.const 0))))

  ;; ============================================================
  ;; Real file handles (created by io.open / io.lines).
  ;;
  ;; A handle is a plain $LuaTable carrying its integer fd under the key
  ;; "__fd" plus the method closures below. The host owns the fd registry
  ;; and the file's bytes; these methods just marshal Lua values to/from
  ;; the fs_* host imports. Closing sets __fd to -1 so io.type can report
  ;; "closed file" and the methods can refuse further use.
  ;; ============================================================

  ;; Build the "__fd" key once per call site. Returns a fresh $LuaString.
  (func $io_fd_key (result (ref $LuaString))
    (struct.new $LuaString (array.new_fixed $LuaArr 4
      (i32.const 95) (i32.const 95) (i32.const 102) (i32.const 100)) (i32.const 0)))   ;; __fd

  ;; Extract the fd from a handle, throwing "attempt to use a closed file"
  ;; if $self isn't a handle table or has been closed (__fd absent / < 0).
  (func $file_fd (param $self anyref) (result i32)
    (local $v anyref) (local $fd i32)
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $self)))
      (then (call $io_throw_closed)))
    (local.set $v (call $tab_get_raw (ref.cast (ref $LuaTable) (local.get $self))
                                     (call $io_fd_key)))
    (if (ref.is_null (local.get $v)) (then (call $io_throw_closed)))
    (local.set $fd (i32.wrap_i64 (call $as_int (local.get $v))))
    (if (i32.lt_s (local.get $fd) (i32.const 0)) (then (call $io_throw_closed)))
    (local.get $fd))

  (func $io_throw_closed
    (call $throw_at_top (struct.new $LuaString (array.new_fixed $LuaArr 28
      (i32.const 97)  (i32.const 116) (i32.const 116) (i32.const 101)   ;; atte
      (i32.const 109) (i32.const 112) (i32.const 116) (i32.const 32)    ;; mpt(sp)
      (i32.const 116) (i32.const 111) (i32.const 32)                    ;; to(sp)
      (i32.const 117) (i32.const 115) (i32.const 101) (i32.const 32)    ;; use(sp)
      (i32.const 97)  (i32.const 32)                                    ;; a(sp)
      (i32.const 99)  (i32.const 108) (i32.const 111) (i32.const 115)   ;; clos
      (i32.const 101) (i32.const 100) (i32.const 32)                    ;; ed(sp)
      (i32.const 102) (i32.const 105) (i32.const 108) (i32.const 101)) (i32.const 0)))  ;; file
    (unreachable))

  ;; Decode a negative fs_* return into a (nil, message) pair. errlen is
  ;; (-ret - 1) bytes already sitting in $fmt_buf; -1 means no message, so
  ;; substitute the generic $fallback string.
  (func $io_fail (param $ret i32) (param $fallback (ref $LuaString)) (result (ref $ArgArr))
    (local $errlen i32) (local $msg anyref)
    (local.set $errlen (i32.sub (i32.sub (i32.const 0) (local.get $ret)) (i32.const 1)))
    (if (result (ref $ArgArr)) (i32.gt_s (local.get $errlen) (i32.const 0))
      (then
        (local.set $msg (call $fmt_buf_to_str (local.get $errlen)))
        (array.new_fixed $ArgArr 2 (ref.null any) (local.get $msg)))
      (else
        (array.new_fixed $ArgArr 2 (ref.null any) (local.get $fallback)))))

  ;; Construct a handle table for fd, wiring up its methods.
  (func $make_file_handle (param $fd i32) (result (ref $LuaTable))
    (local $t (ref $LuaTable))
    (local.set $t (call $tab_new))
    (call $tab_set (local.get $t) (call $io_fd_key)
      (call $make_int (i64.extend_i32_s (local.get $fd))))
    (call $tab_set (local.get $t)
      (struct.new $LuaString (array.new_fixed $LuaArr 4
        (i32.const 114) (i32.const 101) (i32.const 97) (i32.const 100)) (i32.const 0))   ;; read
      (global.get $g_file_read))
    (call $tab_set (local.get $t)
      (struct.new $LuaString (array.new_fixed $LuaArr 5
        (i32.const 119) (i32.const 114) (i32.const 105) (i32.const 116) (i32.const 101)) (i32.const 0))  ;; write
      (global.get $g_file_write))
    (call $tab_set (local.get $t)
      (struct.new $LuaString (array.new_fixed $LuaArr 5
        (i32.const 108) (i32.const 105) (i32.const 110) (i32.const 101) (i32.const 115)) (i32.const 0))  ;; lines
      (global.get $g_file_lines))
    (call $tab_set (local.get $t)
      (struct.new $LuaString (array.new_fixed $LuaArr 4
        (i32.const 115) (i32.const 101) (i32.const 101) (i32.const 107)) (i32.const 0))   ;; seek
      (global.get $g_file_seek))
    (call $tab_set (local.get $t)
      (struct.new $LuaString (array.new_fixed $LuaArr 5
        (i32.const 102) (i32.const 108) (i32.const 117) (i32.const 115) (i32.const 104)) (i32.const 0))  ;; flush
      (global.get $g_file_flush))
    (call $tab_set (local.get $t)
      (struct.new $LuaString (array.new_fixed $LuaArr 5
        (i32.const 99) (i32.const 108) (i32.const 111) (i32.const 115) (i32.const 101)) (i32.const 0))   ;; close
      (global.get $g_file_close))
    (local.get $t))

  ;; io.open(path [, mode]) -> handle, or (nil, message) on failure.
  (func $builtin_io_open (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $path anyref) (local $mode anyref) (local $fd i32)
    (local.set $path (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $path)))
      (then (call $throw_at_top (struct.new $LuaString (array.new_fixed $LuaArr 13
        (i32.const 98) (i32.const 97) (i32.const 100) (i32.const 32)        ;; bad(sp)
        (i32.const 111) (i32.const 112) (i32.const 101) (i32.const 110)     ;; open
        (i32.const 32) (i32.const 112) (i32.const 97) (i32.const 116)       ;; (sp)pat
        (i32.const 104)) (i32.const 0))) (unreachable)))                                  ;; h -> "bad open path"
    ;; mode: a string or nil (nil -> default "r").
    (local.set $mode (call $args_at (local.get $args) (i32.const 1)))
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $mode)))
      (then (local.set $mode (struct.new $LuaString
        (array.new_fixed $LuaArr 1 (i32.const 114)) (i32.const 0)))))   ;; "r"
    (local.set $fd (call $host_fs_open (local.get $path) (local.get $mode)))
    (if (i32.lt_s (local.get $fd) (i32.const 0))
      (then (return (call $io_fail (local.get $fd)
        (struct.new $LuaString (array.new_fixed $LuaArr 11
          (i32.const 111) (i32.const 112) (i32.const 101) (i32.const 110)   ;; open
          (i32.const 32) (i32.const 102) (i32.const 97) (i32.const 105)     ;; (sp)fai
          (i32.const 108) (i32.const 101) (i32.const 100)) (i32.const 0))))))             ;; led
    (array.new_fixed $ArgArr 1 (call $make_file_handle (local.get $fd))))

  ;; file:read(...) — one result per format arg, from this handle's fd.
  (func $file_read (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (call $io_read_impl (local.get $args) (i32.const 1)
      (call $file_fd (call $args_at (local.get $args) (i32.const 0)))))

  ;; file:write(...) — concat the args (after self) and write at the
  ;; cursor. Returns the file on success so writes can chain.
  (func $file_write (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $fd i32) (local $acc anyref) (local $r i32)
    (local.set $fd (call $file_fd (call $args_at (local.get $args) (i32.const 0))))
    (local.set $acc (call $io_concat_from (local.get $args) (i32.const 1)))
    (if (i32.eqz (ref.is_null (local.get $acc)))
      (then
        (local.set $r (call $host_fs_write (local.get $fd) (local.get $acc)))
        (if (i32.lt_s (local.get $r) (i32.const 0))
          (then (return (call $io_fail (local.get $r)
            (struct.new $LuaString (array.new_fixed $LuaArr 11
              (i32.const 119) (i32.const 114) (i32.const 105) (i32.const 116)   ;; writ
              (i32.const 101) (i32.const 32) (i32.const 101) (i32.const 114)    ;; e(sp)er
              (i32.const 114) (i32.const 111) (i32.const 114)) (i32.const 0))))))))           ;; ror
    (array.new_fixed $ArgArr 1 (call $args_at (local.get $args) (i32.const 0))))

  ;; file:seek([whence [, offset]]) -> new position, or (nil, message).
  ;; whence: "set" (0), "cur" (1, default), "end" (2).
  (func $file_seek (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $fd i32) (local $whence i32) (local $offset i64) (local $wv anyref)
    (local $wbytes (ref $LuaArr)) (local $r i64)
    (local.set $fd (call $file_fd (call $args_at (local.get $args) (i32.const 0))))
    (local.set $whence (i32.const 1))   ;; "cur"
    (local.set $wv (call $args_at (local.get $args) (i32.const 1)))
    (if (ref.test (ref $LuaString) (local.get $wv))
      (then
        (local.set $wbytes (struct.get $LuaString $bytes
          (ref.cast (ref $LuaString) (local.get $wv))))
        (if (i32.gt_s (array.len (local.get $wbytes)) (i32.const 0))
          (then
            ;; dispatch on first char: 's'et / 'c'ur / 'e'nd
            (if (i32.eq (array.get_u $LuaArr (local.get $wbytes) (i32.const 0)) (i32.const 115))
              (then (local.set $whence (i32.const 0)))
              (else (if (i32.eq (array.get_u $LuaArr (local.get $wbytes) (i32.const 0)) (i32.const 101))
                (then (local.set $whence (i32.const 2))))))))))
    (if (i32.gt_s (array.len (local.get $args)) (i32.const 2))
      (then (local.set $offset (call $as_int_co (call $args_at (local.get $args) (i32.const 2))))))
    (local.set $r (call $host_fs_seek (local.get $fd) (local.get $whence) (local.get $offset)))
    (if (i64.lt_s (local.get $r) (i64.const 0))
      (then (return (array.new_fixed $ArgArr 2 (ref.null any)
        (struct.new $LuaString (array.new_fixed $LuaArr 11
          (i32.const 115) (i32.const 101) (i32.const 101) (i32.const 107)   ;; seek
          (i32.const 32) (i32.const 101) (i32.const 114) (i32.const 114)    ;; (sp)err
          (i32.const 111) (i32.const 114) (i32.const 32)) (i32.const 0))))))              ;; or(sp)
    (array.new_fixed $ArgArr 1 (call $make_int (local.get $r))))

  ;; file:flush() -> the file, or (nil, message).
  (func $file_flush (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $r i32)
    (local.set $r (call $host_fs_flush
      (call $file_fd (call $args_at (local.get $args) (i32.const 0)))))
    (if (i32.lt_s (local.get $r) (i32.const 0))
      (then (return (call $io_fail (local.get $r)
        (struct.new $LuaString (array.new_fixed $LuaArr 11
          (i32.const 102) (i32.const 108) (i32.const 117) (i32.const 115)   ;; flus
          (i32.const 104) (i32.const 32) (i32.const 101) (i32.const 114)    ;; h(sp)er
          (i32.const 114) (i32.const 111) (i32.const 114)) (i32.const 0))))))             ;; ror
    (array.new_fixed $ArgArr 1 (call $args_at (local.get $args) (i32.const 0))))

  ;; file:close() -> true, or (nil, message). Marks the handle closed
  ;; (__fd = -1) either way so further use raises "closed file".
  (func $file_close (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $fd i32) (local $r i32) (local $t (ref $LuaTable))
    (local.set $t (call $arg_table (call $args_at (local.get $args) (i32.const 0))))
    (local.set $fd (call $file_fd (local.get $t)))
    (local.set $r (call $host_fs_close (local.get $fd)))
    (call $tab_set (local.get $t) (call $io_fd_key) (call $make_int (i64.const -1)))
    (if (i32.lt_s (local.get $r) (i32.const 0))
      (then (return (call $io_fail (local.get $r)
        (struct.new $LuaString (array.new_fixed $LuaArr 11
          (i32.const 99) (i32.const 108) (i32.const 111) (i32.const 115)    ;; clos
          (i32.const 101) (i32.const 32) (i32.const 101) (i32.const 114)    ;; e(sp)er
          (i32.const 114) (i32.const 111) (i32.const 114)) (i32.const 0))))))             ;; ror
    (array.new_fixed $ArgArr 1 (global.get $g_true)))

  ;; file:lines() -> (iterator, file, nil) for generic-for. Validates the
  ;; handle is open, then defers to the shared line iterator. Format args
  ;; are not yet honoured; the iterator always reads one line ("l").
  (func $file_lines (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (drop (call $file_fd (call $args_at (local.get $args) (i32.const 0))))
    (array.new_fixed $ArgArr 3
      (global.get $g_io_lines_iter)
      (call $args_at (local.get $args) (i32.const 0))
      (ref.null any)))

  ;; The generic-for iterator behind io.lines / file:lines. State (arg 0)
  ;; is the handle. Reads one line; at EOF it closes the file and returns
  ;; nil to end the loop. Never throws on a closed handle — just ends.
  (func $io_lines_iter (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $state anyref) (local $v anyref) (local $fd i32) (local $w i32)
    (local $t (ref $LuaTable))
    (local.set $state (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $state)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $t (ref.cast (ref $LuaTable) (local.get $state)))
    (local.set $v (call $tab_get_raw (local.get $t) (call $io_fd_key)))
    (if (ref.is_null (local.get $v))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $fd (i32.wrap_i64 (call $as_int (local.get $v))))
    (if (i32.lt_s (local.get $fd) (i32.const 0))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $w (call $host_fs_read (local.get $fd) (i32.const 0) (i32.const 0)))
    (if (i32.lt_s (local.get $w) (i32.const 0))
      (then
        ;; EOF: close and mark the handle closed, then end the loop.
        (drop (call $host_fs_close (local.get $fd)))
        (call $tab_set (local.get $t) (call $io_fd_key) (call $make_int (i64.const -1)))
        (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (array.new_fixed $ArgArr 1 (call $fmt_buf_to_str (local.get $w))))

  ;; io.lines(path) -> (iterator, file, nil). Unlike io.open, a failed
  ;; open raises rather than returning nil.
  (func $builtin_io_lines (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $path anyref) (local $fd i32)
    (local.set $path (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.eqz (ref.test (ref $LuaString) (local.get $path)))
      (then (call $throw_at_top (struct.new $LuaString (array.new_fixed $LuaArr 16
        (i32.const 98) (i32.const 97) (i32.const 100) (i32.const 32)        ;; bad(sp)
        (i32.const 97) (i32.const 114) (i32.const 103) (i32.const 32)       ;; arg(sp)
        (i32.const 116) (i32.const 111) (i32.const 32)                      ;; to(sp)
        (i32.const 108) (i32.const 105) (i32.const 110) (i32.const 101) (i32.const 115)) (i32.const 0)))  ;; lines
        (unreachable)))
    (local.set $fd (call $host_fs_open (local.get $path)
      (struct.new $LuaString (array.new_fixed $LuaArr 1 (i32.const 114)) (i32.const 0))))   ;; "r"
    (if (i32.lt_s (local.get $fd) (i32.const 0))
      (then
        ;; Open failed: raise with the host message if present, else generic.
        (if (i32.lt_s (local.get $fd) (i32.const -1))
          (then (call $throw_at_top (call $fmt_buf_to_str
            (i32.sub (i32.sub (i32.const 0) (local.get $fd)) (i32.const 1)))))
          (else (call $throw_at_top (struct.new $LuaString (array.new_fixed $LuaArr 11
            (i32.const 111) (i32.const 112) (i32.const 101) (i32.const 110)   ;; open
            (i32.const 32) (i32.const 102) (i32.const 97) (i32.const 105)     ;; (sp)fai
            (i32.const 108) (i32.const 101) (i32.const 100)) (i32.const 0)))))              ;; led
        (unreachable)))
    (array.new_fixed $ArgArr 3
      (global.get $g_io_lines_iter)
      (call $make_file_handle (local.get $fd))
      (ref.null any)))

  ;; io.type(v): "file" for an open handle, "closed file" for a closed
  ;; one, nil for anything that isn't a handle.
  (func $io_type (type $LuaFn)
    (param $self (ref $LuaClosure)) (param $args (ref $ArgArr)) (result (ref $ArgArr))
    (local $v anyref) (local $fdv anyref) (local $fd i32)
    (local.set $v (call $args_at (local.get $args) (i32.const 0)))
    (if (i32.eqz (ref.test (ref $LuaTable) (local.get $v)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $fdv (call $tab_get_raw (ref.cast (ref $LuaTable) (local.get $v))
                                       (call $io_fd_key)))
    (if (ref.is_null (local.get $fdv))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (if (i32.eqz (call $is_int (local.get $fdv)))
      (then (return (array.new_fixed $ArgArr 1 (ref.null any)))))
    (local.set $fd (i32.wrap_i64 (call $as_int (local.get $fdv))))
    (if (i32.ge_s (local.get $fd) (i32.const 0))
      (then (return (array.new_fixed $ArgArr 1
        (struct.new $LuaString (array.new_fixed $LuaArr 4
          (i32.const 102) (i32.const 105) (i32.const 108) (i32.const 101)) (i32.const 0))))))   ;; file
    (array.new_fixed $ArgArr 1
      (struct.new $LuaString (array.new_fixed $LuaArr 11
        (i32.const 99) (i32.const 108) (i32.const 111) (i32.const 115)    ;; clos
        (i32.const 101) (i32.const 100) (i32.const 32)                    ;; ed(sp)
        (i32.const 102) (i32.const 105) (i32.const 108) (i32.const 101)) (i32.const 0))))   ;; file
