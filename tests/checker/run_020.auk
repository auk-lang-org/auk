struct P { x: int, y: int, name: str }
fn grade(n: int): str when n >= 90 = "A"
fn grade(_: int): str = "B"
fn main() {
  var i = 0
  let v = loop {
    i += 1
    if i * i > 50 { break i }
  }
  print("v={v} pi={3.14159:.2} [{"ab":>5}] [{42:05}] [{'x':^5}]")
  for k, n in {"b": 2, "a": 1} { print("{k}={n}") }
  let q = P { x: 9, ..P { x: 1, y: 2, name: "p" } }
  print(q)
  print("{grade(95)}{grade(10)}")
  var total = 0
  for j in 0..10 {
    if j % 2 == 0 { continue }
    if j > 7 { break }
    total += j
  }
  print(total)
  let s = "GET /users/42"
  match s {
    "GET /users/" + id => print("user {id}")
    _ => print("?")
  }
  print([3, 1, 2].sort().reverse())
  print("a b a".split().counts())
}
