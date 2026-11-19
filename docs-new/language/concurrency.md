# Concurrency

Auk's concurrency model is small: `async fn` starts **tasks**, `await` collects their results,
**channels** carry messages between them, and tasks **share nothing**. A task that crashes
takes down only itself, which is what makes supervision possible.

## Tasks

An `async fn` is an ordinary function that can also run as a task. What you do with the call
decides which:

```auk
async fn fetch(id: int): str uses time {
  time.sleep(50)            // stands in for a slow request
  "page {id}"
}

fn main() uses time {
  let a = await fetch(1)                           // run it and wait
  print(a)                                         // page 1

  let (b, c) = await (fetch(2), fetch(3))          // both at once: about 50 ms, not 100
  print("{b}, {c}")                                // page 2, page 3

  let pages = await [4, 5, 6].map(i => fetch(i))   // a whole list at once
  print(pages)                                     // ["page 4", "page 5", "page 6"]

  let t = fetch(7)                                 // start it; t is a Task<str>
  print(t.done())                                  // false: main carries on meanwhile
  print(await t)                                   // page 7
}
```

- `await f(x)` runs the call and waits for it.
- `await (f(x), g(y))` and `await [tasks]` run everything concurrently and wait for all of it.
- Storing the call (`let t = f(x)`) starts a task and gives you a `Task<T>` to await later.
- An `async fn` call must be awaited, stored or returned. Dropping one on the floor is E0332.
- Outside an `async fn`, `await` simply blocks until the result is ready, so `main` needs no
  special setup.

Each task runs on its own thread, so CPU-bound tasks run in parallel.

Errors combine with tasks the way you would expect. An `async fn` returning `T!` gives a
`T!` when awaited, and `?` applies after the `await`:

```auk
async fn flaky(id: int): str! uses time {
  time.sleep(10)
  if id == 2 { fail("no page 2") }
  "page {id}"
}

fn main(): ()! uses time {
  print(await [1, 2, 3].map(i => flaky(i)))   // [ok("page 1"), err(no page 2), ok("page 3")]
  let first = await flaky(1)?                 // (await flaky(1))?
  print(first)                                // page 1
}
```

## First to finish, and cancelling

```auk
async fn after(ms: int, label: str): str uses time {
  time.sleep(ms)
  label
}

fn main() uses time {
  var ts: [Task<str>] = [after(200, "slow"), after(20, "fast")]
  let (i, r) = await any ts        // the index of the first to finish, and its result
  print("{i}: {r}")                // 1: ok("fast")
  ts[0].cancel()                   // we don't need the other one
}
```

`await any` returns the result as a `T!`: if the winning task panicked, you get the panic as
an error instead of crashing yourself.

`t.cancel()` is cooperative. The task stops with the panic `cancelled` at its next loop
iteration or blocking call (a sleep, an `await`, a socket read, a channel operation). A
`catch` inside the task cannot swallow a cancellation.

## Channels

A `Chan<T>` is a queue that tasks send to and receive from:

```auk
async fn producer(c: Chan<int>, n: int) {
  for i in 0..n { c.send(i * i) }
  c.close()
}

fn main() {
  let c: Chan<int> = chan()
  let p = producer(c, 4)
  for v in c { print(v) }      // 0 1 4 9: the loop ends when the channel is closed and empty
  await p
}
```

| | |
|---|---|
| `chan()` | a new channel; its type comes from the annotation |
| `c.send(x)` | add a message |
| `c.recv()` | the next message, waiting for one; `none` once the channel is closed and empty |
| `c.recv_for(ms)` | the same, giving up with `none` after `ms` milliseconds |
| `c.close()` | no more messages |
| `for x in c { }` | receive until closed |

Any number of tasks may send to and receive from one channel, so a pool of workers is a list
of tasks reading the same `Chan<Job>`.

## Tasks share nothing

A task gets **copies** of its arguments, and its result and every channel message are copied
to whoever receives them. Two tasks can never see the same mutable data, so there are no data
races, no locks and nothing to synchronize. Consequences:

- A task started with `let t = f(...)` cannot take a `var` parameter (E0336). `await f(&x)`
  runs in place and can.
- Handles (tasks, channels, sockets, listeners) are the exception: they are shared, which is
  what lets two tasks talk through one channel.
- Each task has its own heap. When a task ends, crashes or is cancelled, everything it
  allocated is freed at once and the connections it held are closed.

## When a task panics

A panic ends only the task it happens in. It is raised again where the task is awaited, and a
`catch` there turns it into an error:

```auk
async fn crash(): int {
  let xs: [int] = []
  xs[3]
}

fn main() {
  let r = catch await crash()
  print(r)   // err(panic: index 3 out of range for length 0 at ...)
  print("still running")
}
```

Tasks are linked to the tasks they start: a task that panics cancels its children that are
still running, so a failed request doesn't leave work orphaned.

## Supervisors

Because a crash is contained and cleaned up, the Erlang recipe works: let it crash, and have
something restart it. The `sup` package (`raft add sup`, effect `time`) provides supervisors:

```auk
fn serve(port: int): ()! uses net {
  var l = net.listen("127.0.0.1", port)?
  loop {
    var c = l.accept()?
    c.write("hello\n".bytes())?
    c.close()
  }
}

fn main(): ()! uses net, time {
  let web = sup.child("web", () => serve(8080))
  let admin = sup.child("admin", () => serve(8081))
  sup.run([web, admin], sup.one_for_one(5, 60_000))?   // at most 5 restarts a minute
}
```

A child is a function returning `()!`. If it returns an error or panics, the supervisor
restarts it from scratch; if restarts come faster than the policy allows, the supervisor
itself fails, and the supervisor above it takes over. `one_for_all` and `rest_for_one`
restart siblings too, and `sup.transient` / `sup.temporary` children are restarted only after
a failure, or never. `sup.restart(f, 5, 60_000)` is the one-child shorthand.

Under [`auk run --live`](../tools/live-reload.md), supervisors are also how running code is
upgraded: when an edit changes a type's layout, only the tasks using that type are stopped,
and their supervisors restart them on the new code.

Next: [Tests, contracts and holes](testing.md).
