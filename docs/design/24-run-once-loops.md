# 24 — Loops in code that runs once

Status: implemented (2026-10). On at the default optimization level; `-O0`
and `--loop-chunk=0` keep every loop inline.

## Problem

V8 compiles a wasm function with its baseline compiler (Liftoff) first and
replaces it with optimized code (TurboFan) once it has run hot — but only
for its *next* call. There is no on-stack replacement for wasm, so a loop in
a function that is called once runs on baseline code for its whole life: the
main chunk's loops, and the loops of a `main()`-style function the chunk
calls once. That code runs at about half the speed of the same loop in a
function that is called repeatedly, and its calls to runtime helpers are
never inlined.

Lua programs put their work exactly there: top-level loops that drive a
simulation, fill a table, scan a grid, or one big function called once
(fannkuch).

## Design

Each outermost loop of a run-once body becomes a wasm function of its own,
`$ol_N`, that runs the loop for a budget of iterations and then returns. The
caller calls it again until it reports that the loop is done. Every call is
a chance for the engine to switch to the optimized code, and inside that
code the runtime helpers can be inlined.

```
(local.set $olc_st (i32.const 0))                ;; OL_START
(loop $ol_again_0
  (call $ol_0 (local.get $olc_st) <state...>)    ;; -> status, state...
  <state...>                                     ;; written back
  (local.set $olc_st)
  (br_if $ol_again_0 (i32.eq (local.get $olc_st) (i32.const 1))))   ;; OL_SUSPENDED
```

**State.** What crosses a call is passed in as parameters and returned as
results: the enclosing body's locals the loop uses (in their unboxed form —
an `i64`, an `f64`, a maybe-typed quadruple, a `$Box` for a captured local),
and the loop's own control state (a numeric for's counter, limit and step;
a generic for's iterator, state and control value). The function copies its
parameters into locals with the same names the enclosing body uses, so the
loop's code is emitted exactly as it would be inline. Locals declared inside
the loop are its own.

**Suspending.** Every loop in the function counts a budget down at its
header; the outlined loop's own header returns `OL_SUSPENDED` once it has
run out. The header is the point where nothing of the next iteration has
run — before a while's condition, a repeat's body, a numeric for's exit
test, a generic for's iterator call — so returning there and resuming there
is unobservable. Only the first call runs the loop's setup (a for's bounds,
a generic for's explist and closing value); a resumed call has its state.

**Leaving.** `break` and falling off the end report `OL_DONE`. A `return`
inside the loop closes what is open, hands its value back with
`OL_RETURN`, and the caller returns it — the value in the shape of the
enclosing entry (a typed `i64`/`f64`, an `anyref`, or a result array). It is
never a tail call, which costs nothing: a run-once function is not part of a
recursion. A loop with a `goto` to a label outside it stays inline.

**Which bodies.** The main chunk; and a local function that the main chunk
mentions exactly once, as the callee of a call outside any loop, whose local
is never reassigned and never captured (so nothing else, the function itself
included, can call it again). A main chunk with a `goto` is left alone,
since a backward goto is a loop too.

**Budget.** 65536 iterations per call (inner loops count), set by
`codegen_loop_chunk` / `--loop-chunk=N`. Anything from 4K to 512K performs
the same on the benchmarks; larger budgets delay switching to optimized code,
smaller ones only add calls. The test suite also runs every e2e fixture and
differential case with a budget of 1, so every iteration suspends and
resumes.

## Results

| bench | before | after |
|---|---:|---:|
| fannkuch | 1.00 s | 0.46 s |
| particles | 0.91 s | 0.68 s |
| closures | 0.104 s | 0.094 s |
| oo | 0.287 s | 0.270 s |

The rest are unchanged; modules grow 1–6%. Note that the benchmarks' `TIME`
is `os.clock()`, the process's CPU time, which includes V8's background
compiler threads: outlining gives V8 more functions to optimize, so a program
whose loops are short can show slightly more CPU time while finishing sooner.

## Limits

- Suspension happens only at the outlined (outermost) loop's header. An outer
  loop with few iterations around a long inner loop runs its first iterations
  on baseline code until the first return.
- A global `function main() ... end`, or a function called once from another
  run-once function, is not recognized.
