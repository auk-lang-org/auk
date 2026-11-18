enum T { One(v: int), Two(a: int, b: int) }

struct Pt { x: int, y: int }

fn main() {
  let t = T.One(1)
  let One(v) = t
  let (a, some(b)) = (1, some(2))
  for (i, Two(x, _)) in [(1, T.Two(1, 2))] { print(x) }
  for k, [h, ..] in [[1], [2]] { print(h) }
  let f = (One(n)) => n
  let One(w) = T.One(3) else { return }
  print(v + a + b + f(t) + w)
}
