struct P { x: int, ys: [str] }
fn main() {
  var a = "one"
  var b = "two"
  (a, b) = (b, a)
  print("{a} {b}")
  var p = P { x: 1, ys: ["k"] }
  var xs = [10, 20, 30]
  (p.x, xs[2], (a, b)) = (5, 99, ("x", "y"))
  print("{p.x} {xs} {a} {b}")
  (p.ys, b) = (["m", a], p.ys[0])
  print("{p.ys} {b}")
  var m = {"k": 1}
  (m["k"], m["j"]) = (2, 3)
  print(m)
}
