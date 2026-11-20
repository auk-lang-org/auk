# Ownership at last use

Status: **approved 2026-11-19**, phases 0–1 in progress. Follows up item (1) of `mem-pot-results.md`.

## The problem

Auk values have value semantics, implemented with reference counting and copy-on-write: a
change to a list, map, string or boxed node copies it first unless its refcount is 1. So
performance depends on whether the compiler releases references the program can no longer
use. Today it often doesn't, in three separate ways. Each one makes a natural loop quadratic.
Measured with `auk build` on 2026-11-19 (programs in the appendix):

| case | code | 40k | 80k | 160k |
|---|---|---|---|---|
| **A** container slot | `var xs = m.get(k) else []; xs.push(i); m[k] = xs` | 0.13 s (20k) | 0.52 s (40k) | n/a |
| A, emptied by hand | same, plus `m[k] = []` after the get | 0.00 s | 0.01 s | n/a |
| **B** local | `var w = v; w.push(i); v = w` | 0.21 s | 0.63 s | 2.70 s |
| **C** parameter | `v = add(v, i)` where `add` copies `xs` into a var and pushes | 0.21 s | 0.77 s | 2.75 s |

(Case A was run at 10k/20k/40k; the doubling-to-quadrupling shape is the point.)

These are three different problems with three different fixes:

- **A. A container slot keeps its reference.** `m.get(k)` retains the element, so the map and
  `xs` both hold it and the push copies. The slot is overwritten by `m[k] = xs` before anything
  reads it again, so it's dead in between. `move_out` (`compiler/src/mir/lower.auk:1243`)
  already handles exactly this for `var g = items[k] … items[k] = g`, but not for
  `get(k) else d`, and never through a `var` parameter. The FLAC workarounds
  (`var ch = chans[c]; chans[c] = []; …; chans[c] = ch` and `var out = out0; out0 = []`) are
  this case done by hand. **Changing the calling convention doesn't fix it.**
- **B. A local keeps its reference until it's reassigned or its scope ends.** `var w = v`
  retains, and `v` still holds the list while `w.push` runs, although `v` is never read
  again before it's overwritten. This is purely intra-procedural.
- **C. A parameter is borrowed, so the caller keeps its reference during the call.**
  Parameters are borrowed (`lower.auk:9`). In `v = add(v, i)` the caller holds `v` for the
  whole call, so the refcount inside `add` is at least 2. The same applies to the BST:
  `reduce` holds `acc` while `insert` runs through a closure, so no path node ever has
  refcount 1. Fixing this needs the calling convention change, and closures too.

The order of the fixes follows from that: B is the base everyone needs (a "last use" analysis),
A extends an existing optimization, C builds on B and is the one that changes ABIs.

## What exists to build on

- `Val { c, ty, owned }` and `own(v)` (`lower.auk:389`): every place that needs an owned value
  already goes through `own`/`own_as`/`hold`, which either moves a temporary
  (`unregister`) or emits a retain. That's the one funnel a move has to hook into.
- `move_out` (`lower.auk:1243`): take an element out, leave a zero, put it back.
- `auk_release` / `rc.release` are null-safe (`runtime/src/rc.auk:191,229`), and `g.zero(ty)`
  gives a value whose release is a no-op. A zeroed slot works as the "moved-from" state, so
  no drop flags are needed.
- Self tail calls already treat parameters as owned copies (`begin_fn`, `tail_call`): retain
  at entry, release before the jump. With owned parameters that retain goes away.
- `auk_arr_push_own` (`lower.auk:2056`): the list takes an owned element without a retain.
- The program-exit work (`release_at_exit`) already computes which types can reach a handle.

## Design

### 1. Last-use analysis (per function, before lowering)

This is a backward liveness pass over the typed AST of one function body. It produces
`moves: {expr_id: bool}`, the `Name` reads of a local that are its last use on every path
from that read.

- Structured control flow only, which Auk has: `if`/`match` arms join, `loop`/`while`/`for`
  iterate to a fixpoint (a local read in a loop body is live around the back edge unless it's
  assigned before the next read in the same iteration), `break`/`continue`/`return`/`?`/`fail`
  end paths. A local read in a `match` guard isn't a move (guards may fail).
- A read is a candidate only if the local is a plain frame variable of an RC'd type. These are
  never moved:
  - `var` parameters (pointers to the caller's variable)
  - locals captured by a `catch` (also pointers; a caught panic would see the hole)
  - locals whose type can reach a handle. Moving changes *where* the final release happens,
    and releasing a task handle waits for the task, so the timing would be observable.
  - anything in a `--debug` build (`move_out` already backs off there: a debugger would show
    a hole)
- Order within an expression matters: in `f(xs, xs.len())`, the first `xs` isn't the last
  use. The analysis walks arguments in evaluation order, the same order `lower` evaluates
  them in.
- A closure literal that captures `x` counts as a read of `x` at the closure's creation. A
  capture at its last use moves into the environment instead of being retained.

This is a separate module (`mir/lower/live.auk`) that runs once per instance and is stored on
`FnState`. It's cheap: one walk per body, plus fixpoint passes per loop.

### 2. Moving in `lower` (fixes B)

A `Name` read at a move site lowers to a borrowed `Val` with a new field,
`from: mir.Ex?`, holding the local's slot. Nothing changes for consumers that only borrow it
(a comparison, a borrowed argument): the slot keeps the value and releases it at scope end, as
today. In `own(v)`, when `v.from` is set, the move happens: no retain, and a zero is stored
into the slot. So the move happens only where it helps, and only `own` needs to know about it.

`var w = v` (case B) then does no retain and zeroes `v`, so `w.push` sees refcount 1.
`v = w` is a move of `w` into `v` (assign: `own_as`), and `v`'s old value is the zero.

`own` callers that gain moves for free: `let`/`var` initializers, assignment, list/map/struct
literals and variant constructors (`Variant` in `call_target`), `return` and block tails,
`push` (`auk_arr_push_own` for named locals, not just temporaries), closure captures, task
arguments.

### 3. Take and put on containers (fixes A)

Generalize `move_out`:

- Recognize `var x = c.get(k) else d` and `var x = c.get(k) ?? d` as takes, as well as
  `c[k]`. The take zeroes the slot if the key is present, and the fallback runs otherwise.
- Allow the store back to come from any later statement in the same block (it already does).
  Keep the existing rules: no exits in between, no mention of `c`, the index expression's
  names unchanged.
- **`var` parameters (decision 1).** Taking from `c` when `c` is a `var` parameter is
  observable only if a panic between the take and the put is caught by a caller that then
  reads its variable. That's allowed: such a variable holds an unspecified but valid value.

This is the only part that fixes the example in the request (`m.get(k) else []`), and it's
independent of 4 and 5. It can land first.

### 4. Owned parameters for direct calls (fixes C)

Each instance gets a **parameter mode** per non-`var` RC'd parameter: `owned` or `borrowed`.
They're inferred, not declared, in the style of Lean 4's borrow inference and Koka's Perceus:

- A parameter is **owned** if its body *consumes* it: some use is at a move site (section 1)
  whose consumer calls `own`. That covers `var ys = xs`, storing it in a structure, returning
  it, passing it to another function's owned parameter, or capturing it.
- Otherwise it's **borrowed**, which is today's convention with zero RC cost.
- The modes of mutually recursive functions depend on each other: compute them over the call
  graph's SCCs, starting from `borrowed` and promoting until nothing changes.
- This runs as a pre-pass over all instances before any body is lowered, since callers need
  their callees' modes. The modes are stored with the instance signature in `Gen`.

At a call site, an argument to an owned parameter goes through `own` (a move if it's at its last
use or a temporary, otherwise a retain). Arguments to borrowed parameters work as today. In the
callee, an owned parameter is registered in the body scope for release (as the tail-call path
does now) and is a movable local like any other.

Every place that calls an instance directly has to follow the callee's modes: `call_target`
(`Instance`), `trace_wrapper`, `ensures_wrapper`, `tail_call`, the task thunks in `spawn`,
the test registration, and `main`. Wrappers forward ownership unchanged. Extern and runtime
functions keep borrowed parameters, as now.

`v = add(v, i)` then passes `v` by move (it's reassigned right after), `add` moves `xs` into
`ys`, and the push is in place.

### 5. Closures and vtables (fixes the BST through `reduce`)

An indirect call doesn't know its target, so `(A) => B` needs one convention. **Owned for RC'd
parameters** (decision 2):

- The `dk_fv` thunk (`fn_value`) and the vtable method thunks (`vtable`) adapt: for a target
  parameter that's borrowed, the thunk releases the argument after the call. For an owned one,
  it forwards it.
- Lambda bodies use the owned convention directly.
- Then `acc = f(acc, x)` in `reduce` moves `acc` into the closure, `insert` owns the tree,
  and with phase 6 the path is rebuilt in place.
- The cost: an indirect call whose argument isn't at its last use pays a retain/release pair
  it doesn't pay today. `map`/`filter` over a `[str]` do this per element (`x` is borrowed
  from the list). For `[int]` and other non-RC elements there's no cost. This has to be
  measured (gate below), since RC operations are atomic.
- If the gate fails, keep indirect calls borrowed. Then A, B and C are fixed for direct calls,
  and the BST case still needs the manual style (`insert` called directly in a loop).

### 6. Reuse in place (the rest of mem-pot item 1)

With an owned scrutinee, a `match` arm that destructures `Node(l, x, r)` and builds a
`Node(…)` of the same layout reuses the cell when its refcount is 1, and otherwise allocates
as today. This is Perceus reset/reuse: one refcount check per arm, instead of a release plus an
allocation. It needs 4 (and 5 for the BST via `reduce`) to ever see refcount 1. It's a separate
phase because it touches `pat.auk` and `progen`'s variant construction, not the convention.

## Phases

Each phase lands separately and has to pass the same bar: `./build.sh --check --test` passes,
stage 3 is bit-identical to stage 2, the leak-check tests pass, `tests/perf` shows no
benchmark slower by more than 2%, and the phase's micro-benchmarks scale linearly.

| phase | what | fixes | size |
|---|---|---|---|
| 0 | COW-copy counter in the runtime (`AUK_STATS=1` prints copies at exit) and the `ownership` integration suite, which asserts copy counts instead of timing (cases A/B/C/BST added as each phase fixes them) | measurement | small |
| 1 | Take/put generalization (section 3): `get(k) else d` on maps, `var` parameters with list/map elements | A | small |
| 2 | `live.auk` + moves through `own` (sections 1–2) | B | medium |
| 3 | Parameter modes, direct calls, wrappers (section 4) | C | large |
| 4 | Indirect ABI + thunks (section 5), behind the perf gate | BST via closures | medium |
| 5 | Reuse in place (section 6) | BST node allocations | medium |

### Progress

- **Phases 0–1 (2026-11-19):** `rc.auk_note_cow` counts copies in `ensure_unique_cap` (lists),
  `auk_map_make_unique`, `auk_str_append` and the generated `box_unique`; `auk_leak_check`
  prints them under `AUK_STATS`, from the same baseline as the leak check (so `auk run`
  counts only the program's). `move_out` takes `m.get(k) else d` and works through `var`
  parameters. Case A: 996 copies per 1000 iterations → 0. Tests:
  `tests/runner/src/suite/ownership.auk`. Not done in phase 1: `xs.get(i) else d` on lists
  (rare; `xs[i]` already works).

- **Phase 2 (2026-11-19):** `mir/lower/live.auk` (the analysis) and the move in `own`, plus
  `push` of a moved local (`auk_arr_push_own`). Locals move only if a scope owns their
  variable (so borrowed parameters and borrowed pattern bindings never do), their type can't
  reach a handle, and the read isn't followed by another mention in the same statement.
  Conservative where order is unclear: closure and `catch` bodies, guards, struct bases and
  shorthand fields, assignment targets other than a plain name, and the roots of
  `match`/`is`/`for`. `AUK_NO_MOVES=1` turns it off at compile time. Case B: 1000 copies → 0.
  Not moved yet: values stored by runtime calls that retain (`m[k] = x`, `xs[i] = x`).
  Two bugs found while bringing it up, both fixed and covered by `tests/fixtures/moves.auk`:
  an earlier read in the same statement can still be a pending borrowed value (interpolation
  parts), so a move needs the local's only mention in its statement; and a pattern binding
  the whole matched value (`match ty { t => t }`) shares the matched variable, so a local
  moves only if no other local is bound to its variable. The second one miscompiled the
  compiler itself (found by bisecting with `AUK_MOVES_LIMIT`/`AUK_MOVES_LOG`).
  Found along the way (pre-existing, both with and without moves): `(xs, { xs = ys; 1 })`
  gives `([3], 1)`. The tuple reads `xs` after the block reassigns it.

Then remove the hand-written workarounds that the compiler now handles (FLAC's
`chans[c] = []`, `out0 = []` and the like) one package at a time, keeping each package's
differential fuzz.

## Risks

- **Compiler bootstrapping.** The compiler compiles itself with these changes. A wrong move
  is a use-after-zero, which shows up as an empty list or a null dereference, and it can show
  up in stage 2 rather than in tests. Phase 2 should land with an `AUK_NO_MOVES=1` switch, so a
  stage that misbehaves can be rebuilt without moves.
- **Release timing.** Moves change which scope releases a value. Excluding handle-reachable
  types covers the observable case (task handles), but leak-check tests will catch accounting
  mistakes.
- **Debug builds stay slow** (decision 3). With moves off under `--debug`, a program that
  relies on them for linear time is still quadratic in the debugger.
- **Compile time.** Liveness per body plus the SCC pre-pass. Measure with `auk build
  compiler/src/main.auk` against `design/perf-baseline.md`.

## Decisions (2026-11-19)

1. **Holes in `var` parameters: allowed.** A variable passed by `&` to a call that panicked
   holds an unspecified but valid value after a caller catches the panic. Take and put
   (section 3) applies through `var` parameters.
2. **Closure ABI: owned, perf-gated.** Phase 4 ships only if no `tests/perf` benchmark is
   more than 2% slower. Otherwise indirect calls stay borrowed.
3. **Debugger: moves off under `--debug`**, as `move_out` does today.

## Appendix: the micro-benchmarks

```auk
// A: container slot
var m: {int: [int]} = {}
for i in 0..n {
  let k = i % 4
  var xs = m.get(k) else []
  xs.push(i)
  m[k] = xs
}

// B: local
var v: [int] = []
for i in 0..n {
  var w = v
  w.push(i)
  v = w
}

// C: parameter
fn add(xs: [int], x: int): [int] {
  var ys = xs
  ys.push(x)
  ys
}
var v: [int] = []
for i in 0..n { v = add(v, i) }
```
