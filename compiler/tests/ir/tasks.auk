// Tasks and failure: spawning (deep-copied arguments, a closure argument), `await` of a task,
// a tuple and a list of tasks, `await any`, cancel, `catch`, channels and `for` over one,
// typed errors (`fail`, `err(e)` patterns, `else e =>`), `!` unwraps.

enum Bad { TooBig(n: int), Negative }

struct Job { id: int, tags: [str] }

async fn work(j: Job): int = j.id * 10 + j.tags.len()

async fn run(f: () => int): int = f()

async fn slow(n: int): int! {
  if n > 2 { fail("too slow: {n}") }
  n
}

async fn feed(c: Chan<int>, n: int) {
  for i in 0..n { c.send(i) }
  c.close()
}

fn check(n: int): int!Bad {
  if n < 0 { fail(Bad.Negative) }
  if n > 9 { fail(Bad.TooBig(n)) }
  n * 2
}

fn main() {
  let j = Job { id: 4, tags: ["a", "b"] }
  let t = work(j)
  print(await t)
  let (a, b) = await (work(Job { id: 1, tags: [] }), work(j))
  print(a + b)
  let all = await [work(j), work(j), work(j)]
  print(all)
  let base = 5
  print(await run(() => base + 1))
  let (k, r) = await any [slow(5), slow(1)]
  print("{k} {r}")
  let long = slow(9)
  long.cancel()
  let c: Chan<int> = chan()
  let feeder = feed(c, 4)
  var got = 0
  for x in c { got += x }
  await feeder
  print(got)
  let caught = catch {
    let xs = [1, 2]
    xs[5]
  }
  match caught {
    ok(v) => print(v)
    err(e) => print("caught: {e}")
  }
  var n = 0
  let r2 = catch {
    n += 1
    n
  }
  print("{r2} {n}")
  for x in [3, -1, 12] {
    match check(x) {
      ok(v) => print(v)
      err(TooBig(m)) => print("big {m}")
      err(Negative) => print("neg")
    }
  }
  let v = check(20) else e => {
    print("else {e}")
    0
  }
  print(v)
  print(check(2)!)
}
