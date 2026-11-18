// Closures: captures, var parameters in function types, unpacked tuple parameters, function
// values of functions and variant constructors, closures returning closures.

enum Shape { Circle(r: float), Rect(w: float, h: float), Dot }

struct Counter { n: int, names: [str] }

fn apply(f: (int) => int, x: int): int = f(x)

fn bump(c: var Counter, by: int) {
  c.n += by
  c.names.push("b{by}")
}

fn twice(c: var Counter, g: (var Counter, int) => ()) {
  g(&c, 1)
  g(&c, 2)
}

fn adder(k: int): (int) => int = x => x + k

fn compose(f: (int) => int, g: (int) => int): (int) => int = x => g(f(x))

fn main() {
  let base = 10
  let label = "n="
  let add = (x: int) => x + base
  print(apply(add, 5))
  print(apply(adder(3), 4))
  let h = compose(adder(1), x => x * 2)
  print(h(5))
  var c = Counter { n: 0, names: [] }
  twice(&c, bump)
  twice(&c, (k, by) => k.n += by * 10)
  print("{label}{c.n} {c.names}")
  let pairs = [(1, "a"), (2, "b")]
  let shown = pairs.map((n, s) => "{s}{n}")
  print(shown)
  let mk = Shape.Circle
  let shapes = [mk(1.0), Shape.Rect(2.0, 3.0), Shape.Dot]
  let areas = shapes.map(s => match s {
    Circle(r) => r * r * 3.0
    Rect(w, h) => w * h
    Dot => 0.0
  })
  print(areas)
  let fs: [(int) => int] = [adder(1), adder(2), x => x - base]
  var total = 0
  for f in fs { total += f(100) }
  print(total)
}
