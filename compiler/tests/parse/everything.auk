/// module doc

/// a struct
pub struct Point<T: Show + Eq, U> {
  /// x
  x: float,
  y: [T],
  z: {str: (int, U)},
  w: (int) => str!,
  v: any Show?,
  u: float<m/s^2>?,
  t: Set<Set<int>>!Err,
  s: (),
  r: (int),
}

pub enum E<T> { A, B(int), C(x: T, y: str), }

pub shape Area {
  fn area(self): float
  async fn go(self)
}

imprint TABLE: [int] = [1, 2, 3]
pub let NAME = "x"

test "t" {
  assert f(1) == 2
}

pub async fn f<A>(a: A, b: var [int], (c, d): (int, int), [h, ..t]: [int], 0: int): int!E uses fs, net
  requires a > 0
  ensures result > 0
{
  let x: int = 1
  var y = 2
  y += 1
  y -= 1
  y *= 2
  y /= 2
  y %= 3
  y &= 1
  y |= 1
  y ^= 1
  y <<= 1
  y >>= 1
  let [p, q] = xs else { return 0 }
  let n = parse(s) else e => fail(e)
  let m = {"a": 1, "b": 2}
  let e = {}
  let blk = { 1 }
  let s = "hi {name}, {x:.2} {n:>5} {i + 1:>2} {if a { "x" } else { "y" }} {Point { x: 1 }.x} {m.get(k) else "-"}"
  let r = r"raw {x}"
  let t = """
    multi {x}
      line
    """
  let u = 3.0<m/s> + 5<px>
  let c = x => x * 2
  let c2 = (a, b: int) => a + b
  let c3 = ((i, x), y) => { y }
  let c4 = () => 1
  let c5 = _ => 0
  let pt = Point { x: 1.0, y, ..base }
  let pt2 = geo.Point { x, y, }
  let em = Empty {}
  let w = await (a(), b())
  let w2 = await any ts
  let w3 = await any(ts)
  let w4 = catch f(x)? else 0
  let w5 = catch await t
  let w6 = catch { parse(s)? + xs[i] } else 0
  peek x * 2
  peek (a, b)
  p.peek()
  peek(p)
  for x in xs { continue }
  for i, (a, b) in pairs { break }
  while c { if d { break 42 } }
  loop { break }
  let v = loop { if done() { break 42 } }
  if a { 1 } else if b { 2 } else { 3 }
  if a {
    1
  }
  else {
    2
  }
  match s {
    Circle(r) => 3.14 * r * r
    Rect(w, h) when w == h => w * w
    Shape.Rect(w, h) => w * h
    Need.Required => 0
  }
  match v {
    0 => a, 1 => a
    -1 => b
    -2.5 => c
    'c' => d
    "GET " + rest => rest
    "x" => 1
    true => 2
    (a, b) => 3
    (a,) => 4
    [] => 5
    [a, b] => 6
    [h, ..t] => 7
    [.., last] => 8
    [a, .._, z] => 9
    User { name, age: a, .. } => 10
    {"k": v, 1: w, -1: z, 'c': q, true: r} => 11
    some(x) => 12
    none => 13
    ok(x,) => 14
    err(e) => 15
    x when x > 0 => 16
    _ => total += 1
  }
  xs.map(x => x * 2).filter(x => x > 0)
  rows
    |> filter(p)
    |> map(g)?
  a |> json.encode()
  a |> f()? |> g
  x else y |> f()
  a else b else c
  -2 ** 2
  a + b * c ** d ** e
  a | b ^ c & d << 2 + e
  ~a & -b
  !p.at(c)
  x is some(_) && y
  a < b is true
  a +% b *% c -% d
  xs.max()! + 1
  x??
  f(??)
  (x?).f()
  f(a)(b)
  xs[a..b] + s[0..=2] + m[k]
  t.0 = 1
  a.b[i].c += 1
  f(&xs, 7)
  f(&a.b[0])
  return
}
