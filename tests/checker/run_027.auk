struct Cfg { name: str, ratio: float, tags: [str], limit: int?, nick: str? }
enum Op { Push(n: int), Pop, Jump(to: int, label: str) }
enum Tree { Leaf(v: int), Node(l: Tree, r: Tree) }
struct Emp { name: str, boss: Emp? }
fn sieve(n: int): [int] {
  var composite: [bool] = []
  for _ in 0..=n { composite.push(false) }
  var out: [int] = []
  for i in 2..=n {
    if !composite[i] {
      out.push(i)
      var j = i * i
      while j <= n {
        composite[j] = true
        j += i
      }
    }
  }
  out
}
fn build(d: int): Tree = if d == 0 { Leaf(0) } else { Node(build(d - 1), Leaf(d)) }
let BASE = 1000
imprint COUNT = PRIMES.len() + BASE
imprint PRIMES = sieve(200)
imprint SQUARES = {"one": 1, "two": 4, "three": 9}
imprint CFG = Cfg { name: "auk \"q\" é\n", ratio: 0.1, tags: ["a", "b"], limit: some(3), nick: none }
imprint OPS = [Push(1), Pop, Jump(0, "start")]
imprint TREE = build(2)
imprint EMP = Emp { name: "a", boss: some(Emp { name: "b", boss: none }) }
imprint FLOATS = [[1.5, -0.0, 1e300], []]
imprint V = to_value(CFG)
fn main() {
  print(PRIMES.take(10))
  print(PRIMES.last())
  print(COUNT)
  print(SQUARES)
  print(CFG)
  print(OPS)
  print(TREE)
  print(EMP)
  print(FLOATS)
  print(V)
  var p = PRIMES
  p.push(1)
  var e = EMP
  e.name = "z"
  var m = SQUARES
  m["four"] = 16
  print("{p.len() - PRIMES.len()} {EMP.name} {SQUARES.len()}")
}
