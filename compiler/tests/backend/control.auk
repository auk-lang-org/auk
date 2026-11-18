// The self-hosted back end's corpus (scripts/diff_llvm.sh, diff_mir.sh, run_backend.sh):
// closures, tasks and channels, catch, tail calls, string switches, shapes, contracts.

shape Area { fn area(self): float }

struct Sq { side: float }
struct Circ { r: float }

fn area(s: Sq): float = s.side * s.side
fn area(c: Circ): float = 3.0 * c.r * c.r

fn total(xs: [any Area]): float = xs.map(x => x.area()).sum()

fn biggest(a: Ord, b: Ord): Ord = if a > b { a } else { b }

fn adder(n: int): (int) => int = x => x + n

fn twice(f: (int) => int, x: int): int = f(f(x))

fn count(n: int, acc: int): int = if n == 0 { acc } else { count(n - 1, acc + n) }

fn word(s: str): int = match s {
  "zero" => 0
  "one" => 1
  "two" => 2
  "three" => 3
  "four" => 4
  "five" => 5
  "six" => 6
  _ => -1
}

fn isqrt(n: int): int
  requires n >= 0
  ensures result * result <= n
{
  var r = 0
  while (r + 1) * (r + 1) <= n { r += 1 }
  r
}

async fn square(n: int): int = n * n

async fn produce(c: Chan<int>, n: int) {
  for i in 0..n { c.send(i) }
  c.close()
}

fn risky(xs: [int], i: int): int = xs[i] * 2

fn main() {
  let add3 = adder(3)
  print(twice(add3, 10))
  var k = 5
  let mul = (x: int) => x * k
  k = 7
  print(mul(6))
  print(count(100000, 0))
  print(["zero", "four", "six", "nine"].map(word))
  print(isqrt(50))
  print(biggest(3, 9))
  print(biggest("pear", "apple"))
  let shapes: [any Area] = [Sq { side: 2.0 }, Circ { r: 1.0 }]
  print(total(shapes))
  let (a, b) = await (square(4), square(5))
  print(a + b)
  let all = await [1, 2, 3].map(n => square(n))
  print(all)
  let c: Chan<int> = chan()
  let t = produce(c, 5)
  var sum = 0
  for x in c { sum += x }
  await t
  print(sum)
  let r = catch risky([1, 2], 5)
  match r {
    ok(v) => print("ok {v}")
    err(e) => print("caught: {e}")
  }
  let safe = catch { risky([4], 0) + 1 } else 0
  print(safe)
}
