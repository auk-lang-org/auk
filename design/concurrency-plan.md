# Plan: cheaper tasks — zero-copy sharing, then an M:N scheduler

**Goal:** make concurrency faster without changing the language: large values cross tasks without
being copied, and tasks stop costing an OS thread each. User code, syntax and semantics stay the
same; only the runtime (and a little codegen) changes.

**Today** (`runtime/c/task.c`, `heap.c`, `copy.c`, `chan.c`):
- One pthread per started task; `await` joins it.
- Nothing crosses a task by reference: spawn arguments, `await` results and channel messages are
  deep-copied, so a task's heap can be swept when it crashes (see the comment at the top of
  `heap.c`). Only handles are shared, tracked through each heap's ledger.
- Blocking calls wait in 50 ms slices (`SLICE_MS`) so they can see cancellation.

**Why it is safe to change:** every Auk value is acyclic (copy-on-write data, closures can't
capture themselves), and reference counts are already atomic. A value shared between tasks has
`rc > 1`, so any write copies it first. The only thing deep copying protects is the crash
sweep: no object outside a heap may point into it.

**Rule:** as in `self-host-plan.md`, one moving part at a time, the suite green after every step.
Every step is measured against a baseline taken before it (`tests/perf` plus the benchmarks
below).

---

## Phase 0 — Groundwork (during the `task`/`chan` port to C)

- [ ] Gather every piece of per-thread runtime state into one struct, `AukThreadState`, reached
      through a single `_Thread_local` pointer: catch stack and caught message/location
      (`catch.c`), current heap (`heap.c`), `cur_task` (`task.c`), `show_left`/`dbg_busy`
      (`str.c`), the trace site (`trace.c`) and the debugger's frame stack (`dbg`). No behaviour
      change; this is the struct Phase 2 swaps on a task switch. Cheap to do now while `task.c`
      is being written, costly to retrofit.
- [ ] Keep every blocking wait behind the existing helpers (`auk__wait_fd`, `auk__sleep_ms`,
      the channel waits, `task_join`, `wait_any`). Nothing else may block a task thread.
- [ ] Benchmarks: (a) send/await of a 1 MB / 100 MB `str` and `[int]`; (b) a list of 100k small
      structs through a channel; (c) spawn+await of 10k / 100k trivial tasks; (d) an HTTP server
      with 10k idle keep-alive connections (memory, latency). Record before Phase 1.

## Phase 1 — Zero-copy for leaf buffers

A *leaf buffer* has no references in it: `str`, lists of scalars (`[int]`, `[float]`,
`[bool]`, `[char]`), `pixels.Frame`. Sharing one can't leave anything pointing into a heap.

- [ ] A size threshold (start at 4 KB, tune with benchmark a). Below it, copy as today.
- [ ] Above it, `copy.c` doesn't copy: it *promotes* the buffer to an untracked object (moves it
      off its heap's list, clears the tracked flag) and retains it. If it is already untracked,
      it just retains it.
- [ ] Untracked shared buffers go on the heap ledger like handles: retaining counts, releasing
      subtracts, and the crash sweep releases what's left instead of freeing it. (Generalise the
      ledger from "handles" to "untracked shared objects".)
- [ ] Slice views (`{base, offset, len}`) of a big buffer share the base the same way.
- [ ] Copy-on-write stays as is: a shared buffer has `rc > 1`, so a write copies into the
      writer's heap.
- [ ] `AUK_LEAK_CHECK=1` counts shared buffers correctly; tests: crash a task holding a shared
      buffer, cancel one mid-send, share one buffer across 1000 tasks.

**Exit:** benchmark (a) is flat in payload size above the threshold; nothing else regresses.

## Phase 2 — Move on last use (structured data)

- [ ] When MIR shows a value sent or returned at its last use with `rc == 1`, pass ownership:
      unlink its objects from the sender's heap and link them into the receiver's (O(objects),
      pointer writes only, no allocation or memcpy). Otherwise deep-copy as today.
- [ ] Codegen marks the moving call sites (`spawn` arguments, `send`, the task result); the
      runtime keeps a uniqueness check as a fallback.
- [ ] Optional later: per-task heaps in segments, so a whole segment can change owner in O(1).

**Exit:** benchmark (b) improves; a value used after sending still gets copied (test it).

## Phase 3 — M:N scheduler

Done after `task` and `chan` are in C (self-host Phase 1c), never during the port.

### 3a. Stackful tasks
- [ ] A task gets its own stack (mmap, default 1 MB virtual with a guard page; `AUK_TASK_STACK`
      to change it) and runs on one of N worker threads (N = cores; `AUK_WORKERS`).
- [ ] Context switch: a small assembly routine per target (aarch64, x86-64), saving
      callee-saved registers and the stack pointer, and swapping `AukThreadState` (Phase 0).
- [ ] Generated code is direct-style, so the compiler doesn't change.
- [ ] `catch`'s `sigsetjmp`/`siglongjmp` stay within one task's stack (each task has its own
      catch stack), so they still work. Test: a panic caught after the task moved worker.
- [ ] Work stealing between worker run queues.

### 3b. Blocking without threads
- [ ] A reactor per worker (kqueue on macOS, epoll on Linux) behind `auk__wait_fd`: the task
      parks, the reactor wakes it. TLS (`tls.rs`/its C port) goes through the same calls.
- [ ] Timers for `auk__sleep_ms`, `recv_for`, timeouts; channels, `await` and `await any` park
      and unpark tasks instead of using condition variables.
- [ ] Calls that really block (file I/O, subprocess output, DNS, `uses ffi` calls) run on a
      separate blocking pool; the task parks until they finish.
- [ ] The 50 ms polling slices go: cancelling a parked task wakes it.

### 3c. Fairness and pinning
- [ ] Preemption at the existing loop check: `auk_cancel_pending` becomes a general "look at the
      scheduler" flag, also set by a timer when a task has run past its time slice. One load
      per loop iteration, as now.
- [ ] Pinning from effects: a task whose thunk (by the call graph, as `--live` computes it)
      reaches `uses ffi` or `uses gui` runs on a dedicated thread of its own, as today. C
      libraries that keep thread-local state and macOS UI rules stay correct. The main task
      stays on the main thread.

### 3d. Tools
- [ ] Debugger: pause and inspect per task, not per thread; `auk debug` lists tasks.
- [ ] `--live`: `cancel_running` and the task hint work on scheduled tasks.
- [ ] Traces record the task id, not the thread.

**Exit:** benchmark (c) and (d) improve by an order of magnitude; every existing test passes
with `AUK_WORKERS=1` and with the default; TSan clean.

---

## Risks

- **Deep recursion on fixed-size stacks.** Today a task has a full thread stack. Mitigation: a
  generous virtual stack with a guard page, a clear "stack overflow in task" panic, and the
  env var.
- **Hidden blocking.** A call that blocks outside the helpers stalls a whole worker. The
  Phase 0 rule plus a debug-build check (time spent in a call with no park) catch it.
- **Contention on shared reference counts.** Many cores retaining/releasing one shared buffer
  bounce its cache line. Measure with benchmark (a) across 1000 tasks; if needed, keep
  per-task counts and touch the shared count only once per task.
- **Phase 7 of the self-host plan** (runtime to Auk) must carry the context switch and reactor
  across; keep the assembly isolated in one file.

## Order and size

| Phase | Work | Relative size |
|---|---|---|
| 0 | State struct, benchmarks | small (fold into the C port) |
| 1 | Leaf-buffer sharing | small |
| 2 | Move on last use | medium |
| 3 | M:N scheduler, reactor, pinning, tools | large |
