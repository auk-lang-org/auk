shape Area { fn area(self): float }
struct Sq { s: float }
struct Circ { r: float }
fn area(q: Sq): float = q.s * q.s
fn area(c: Circ): float = 3.0 * c.r * c.r
async fn slow(n: int): int uses time {
  time.sleep(5)
  n * 2
}
fn main() uses time {
  let shapes: [any Area] = [Sq { s: 2.0 }, Circ { r: 1.0 }]
  print(shapes.map(s => s.area()))
  let (a, b) = await (slow(1), slow(2))
  print(a + b)
  let t = slow(10)
  print(await t)
  print(await [1, 2, 3].map(n => slow(n)))
  print(await slow(7))
}
