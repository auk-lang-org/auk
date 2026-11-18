# sup

Supervision the Erlang/OTP way. A supervisor runs its children as tasks, restarts them when they exit, and gives up when restarts come too fast. Giving up means failing, so the supervisor above it restarts it in turn.

**Effects:** `time` (for the restart window).

```auk
fn main(): int! uses net, time {
  let web = sup.child("web", () => serve(8080))
  let jobs = sup.transient("jobs", () => work())
  sup.run([web, jobs], sup.one_for_one(5, 60_000))?   // at most 5 restarts per minute
  0
}

// one child, one-for-one
sup.restart(() => serve(8080), 5, 60_000)?
```

A child is a function `() => ()!`. It exits in one of three ways: it returns normally, it returns an `Err`, or it panics. A panic counts as a failure, just like an `Err`. Every restart calls the function again, so the child starts from scratch. Children share no state with each other.

## API
- `enum Restart { Permanent, Transient, Temporary }`: when to restart an exited child. `Permanent` restarts it always, `Transient` only after a failure, and `Temporary` never.
- `enum Strategy { OneForOne, OneForAll, RestForOne }`: what a restart takes down. `OneForOne` restarts only the child that exited, `OneForAll` restarts every child, and `RestForOne` restarts that child and the children started after it. The others in the group are stopped last-first, then the group restarts in order. A `Temporary` sibling isn't started again.
- `struct Child { id: str, start: () => ()!, restart: Restart }`, built with `child(id, f)` (permanent), `transient(id, f)` or `temporary(id, f)`.
- `struct Policy { strategy: Strategy, intensity: int, period: int }`, built with `one_for_one(intensity, period)`, `one_for_all(..)` or `rest_for_one(..)`. Up to `intensity` restarts are allowed within any `period` ms. One more stops every child and fails the supervisor.
- `run(kids: [Child], p: Policy): ()!`: blocks until every child has exited for good, which returns `ok`, or until the restart limit is hit, which returns an `Err` naming the child and its last exit. Supervisors nest: a child can call `sup.run` itself.
- `restart(f, intensity, period): ()!`: shorthand for `run` with one permanent child under `one_for_one`.

Every exit is reported on stderr (`sup: web exited: err(...); restarting`).

## How it maps to OTP
- Children are tasks. A child's panic ends only that child: the supervisor gets it from `await any` as an `Err`, the equivalent of OTP's `{'EXIT', Pid, Reason}`.
- Children are stopped with `t.cancel()`. It is cooperative: the child stops at its next loop iteration or blocking call. A `catch` inside the child can't hold it.
- With `auk run --live`, a code change that alters the layout of a struct or enum stops only the children that use it. Their supervisor restarts them on the new code, which is OTP's code upgrade without writing `code_change`.
- Tasks are linked to the tasks they start. A supervisor that crashes or is cancelled takes its whole subtree down with it.
- Children share nothing. Each runs in its own heap: its start function (a closure) and everything it captures are copied in. When a child crashes or is stopped, its heap is freed, and so are the connections it still held.
- **Differences from OTP:** there are no named processes, no dynamic `start_child`, and no message queue per task. Use a `Chan<T>` instead.
