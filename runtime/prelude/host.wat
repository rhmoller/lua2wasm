;; Host imports: output, number formatting, transcendental math, stdin, the
;; file registry, and the os shims.

  (import "host" "print" (func $host_print (param anyref)))
  (import "host" "write_raw" (func $host_write_raw (param anyref)))
  ;; Stable, distinct per-object id for the address form of tostring / %p on
  ;; functions and strings (tables carry their own struct $id).
  (import "host" "obj_id" (func $host_obj_id (param anyref) (result i32)))
  (import "host" "warn"  (func $host_warn  (param anyref)))
  ;; host_write_err: stderr counterpart to host_write_raw. Used by the
  ;; io.stderr file handle's :write method.
  (import "host" "write_err" (func $host_write_err (param anyref)))
  ;; host_fmt: format one value into the shared $fmt_buf scratch array.
  ;;   kind: 0 = %d (i_val)   1 = unused (s handled wasm-side)
  ;;         2 = %g (f_val + prec)   3 = %f   4 = %e   5 = %x (i_val)
  ;; Returns the number of bytes written.
  (import "host" "fmt" (func $host_fmt (param i32) (param i64) (param f64) (param i32) (result i32)))
  ;; host_math: dispatch transcendental functions to the JS Math API.
  ;;   0 sin  1 cos  2 tan  3 asin  4 acos  5 atan  6 exp  7 log
  (import "host" "math" (func $host_math (param i32) (param f64) (result f64)))
  ;; host_math2: two-arg math fns.
  ;;   0 atan2(y, x)   1 pow(base, exp)
  (import "host" "math2" (func $host_math2 (param i32) (param f64) (param f64) (result f64)))
  ;; host_read: read from stdin in one of several modes into $fmt_buf.
  ;;   mode 0  -> "l" (line, no \n)
  ;;   mode 1  -> "L" (line, with \n)
  ;;   mode 2  -> "a" (read all remaining)
  ;;   mode 3  -> count: exactly $count bytes (or fewer if EOF)
  ;; Returns the number of bytes written, or -1 on EOF.
  ;; For mode 2 ("a"), 0 bytes means "" — never -1 — so callers can
  ;; distinguish empty-string-at-EOF from genuine EOF for line modes.
  (import "host" "read" (func $host_read (param i32) (param i32) (result i32)))
  ;; host_read_num: skip whitespace, parse one number per Lua syntax.
  ;; Returns the parsed value (int or float subtype) or nil if EOF /
  ;; no number found at the cursor.
  (import "host" "read_num" (func $host_read_num (result anyref)))
  ;; host_fmt_float: render one float directive of string.format. conv is
  ;; the conversion byte (e E f F g G a A, or q for %q's hex-float form),
  ;; flags a bitmask (1 '-', 2 '+', 4 ' ', 8 '#', 16 '0'), width and
  ;; precision as parsed (-1 = no precision). Writes the padded bytes into
  ;; $fmt_buf and returns their count. Primitives only: no string decode.
  (import "host" "fmt_float"
    (func $host_fmt_float (param i32) (param i32) (param i32) (param i32) (param f64) (result i32)))
  ;; host_parse_num: parses a Lua string per Lua semantics (whitespace
  ;; trim, optional sign, decimal int, hex int 0x..., decimal float
  ;; with optional exponent). The optional base (2..36) constrains to
  ;; integer parsing in that base; 0 means "no base specified".
  ;; Returns a Lua value: i31/struct int, $LuaFloat, or null.
  (import "host" "parse_num"
    (func $host_parse_num (param anyref) (param i32) (result anyref)))

  ;; --- filesystem: the host owns a registry of open files keyed by an
  ;; integer fd. io.open returns the fd; the file-handle methods pass it
  ;; back in. Error convention for the i32-returning calls: a negative
  ;; result means failure, and the error message (which the host builds,
  ;; including the offending path) is the first (-ret - 1) bytes of
  ;; $fmt_buf. So -1 means "failed, no message"; callers substitute a
  ;; generic one in that case. ---
  ;; fs_open(path, mode) -> fd (>= 0) on success, else error per above.
  (import "host" "fs_open"
    (func $host_fs_open (param anyref) (param anyref) (result i32)))
  ;; fs_read(fd, mode, count): like host_read, but from file $fd's buffer.
  ;; mode 0=l 1=L 2=a (capped, chunked) 3=count bytes. Writes into
  ;; $fmt_buf, returns the byte length; -1 on EOF (0 for mode 2 / count 0).
  (import "host" "fs_read"
    (func $host_fs_read (param i32) (param i32) (param i32) (result i32)))
  ;; fs_read_num(fd): parse one number from file $fd; null at EOF.
  (import "host" "fs_read_num" (func $host_fs_read_num (param i32) (result anyref)))
  ;; fs_write(fd, str): append/overwrite at the cursor. 0 ok, else error.
  (import "host" "fs_write" (func $host_fs_write (param i32) (param anyref) (result i32)))
  ;; fs_seek(fd, whence, offset): whence 0=set 1=cur 2=end. Returns the
  ;; new absolute position (>= 0), or -1 on error.
  (import "host" "fs_seek"
    (func $host_fs_seek (param i32) (param i32) (param i64) (result i64)))
  ;; fs_flush(fd) / fs_close(fd): 0 ok, else error per the convention.
  (import "host" "fs_flush" (func $host_fs_flush (param i32) (result i32)))
  (import "host" "fs_close" (func $host_fs_close (param i32) (result i32)))

  ;; --- os shims: thin wrappers over the host environment. ---
  ;; host_os_time: current wall-clock time, in unix seconds.
  (import "host" "os_time" (func $host_os_time (result i64)))
  ;; host_os_time_table: unix seconds for a broken-down LOCAL time
  ;; (year, month [1-12], day, hour, min, sec) — the os.time(table) form.
  (import "host" "os_time_table"
    (func $host_os_time_table
      (param i64 i64 i64 i64 i64 i64) (result i64)))
  ;; host_os_clock: CPU time used by the process, in seconds.
  (import "host" "os_clock" (func $host_os_clock (result f64)))
  ;; host_os_getenv: $name is a $LuaString; writes the env value into
  ;; $fmt_buf and returns its length, or -1 if the variable is unset.
  (import "host" "os_getenv"
    (func $host_os_getenv (param anyref) (result i32)))
  ;; host_os_exit: terminate the host process with $code (0 if no code
  ;; was supplied — caller passes $has_code=0 in that case).
  (import "host" "os_exit"
    (func $host_os_exit (param i32) (param i32)))
  ;; host_os_date: format a time per a strftime-ish string. When $fmt is
  ;; null, defaults to "%c". When $has_time is 0, uses the current time.
  ;; The result is written into $fmt_buf and its length returned. A
  ;; return value of -1 signals "this format requested a table" — i.e.
  ;; "*t" or "!*t"; in that case the host has packed 9 i32 fields into
  ;; the first 36 bytes of $fmt_buf (year, month, day, hour, min, sec,
  ;; wday, yday, isdst — each LE).
  (import "host" "os_date"
    (func $host_os_date (param anyref) (param i64) (param i32) (result i32)))
  ;; os_remove(path) / os_rename(old, new): 0 ok, else error per the
  ;; $fmt_buf convention documented on the fs_* imports above.
  (import "host" "os_remove" (func $host_os_remove (param anyref) (result i32)))
  (import "host" "os_rename"
    (func $host_os_rename (param anyref) (param anyref) (result i32)))
  ;; os_tmpname(): writes a fresh temp-file name into $fmt_buf, returns len.
  (import "host" "os_tmpname" (func $host_os_tmpname (result i32)))
