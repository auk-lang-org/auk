fn at(xs: [int], i: int): int = xs[i]
fn parse(s: str): int! {
  let n = int.parse(s) else fail("nan: {s}")
  n
}
async fn boom(n: int): int {
  let xs = [1]
  xs[n]
}
fn bump(n: var int) { n += 1 }
fn main() {
  let xs = [1, 2, 3]
  print(catch at(xs, 1))
  match catch at(xs, 9) {
    ok(v) => print("ok {v}"),
    err(e) => print("caught: {e}"),
  }
  print("{catch parse("12")} {catch parse("x")} {catch at(xs, 7) else 0}")
  var count = 0
  let r = catch {
    bump(&count)
    count += 1
    parse("5")? + at(xs, 5)
  }
  print("count {count} r {r}")
  let t = boom(0)
  let u = boom(5)
  print("{await t} {catch await u}")
  let n = catch {
    let a = catch at(xs, 100)
    print("inner {a is err(_)}")
    at(xs, 50)
  }
  print(n is err(_))
  let m: {str: int} = {}
  print(catch m["k"])
  print("alive")
}
