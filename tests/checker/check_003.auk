
struct Config { name: str }
struct User { id: int, name: str }
enum ParseErr { BadToken(at: int), Eof }
struct Ast { n: int }
struct Point { x: float, y: float }
enum Shape { Circle(r: float), Rect(w: float, h: float) }
fn area(s: Shape): float = match s {
  Circle(r) => 3.14 * r * r
  Rect(w, h) when w == h => w * w
  Rect(w, h) => w * h
}
fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)
fn len([], acc: int): int = acc
fn len([_, ..t]: [int], acc: int): int = len(t, acc + 1)
fn grade(n: int): str when n >= 90 = "A"
fn grade(_: int): str = "B"
fn parse_cfg(text: str): Config! = Config { name: text }
fn load(path: str): Config! uses fs {
  let text = fs.read(path)?
  parse_cfg(text)?
}
fn default(): Config = Config { name: "x" }
fn parse(s: str): Ast!ParseErr {
  if s == "" { fail(Eof) }
  Ast { n: s.len() }
}
fn find(xs: [User], id: int): User? = xs.find(u => u.id == id)
fn first_or_zero(xs: [int]): int {
  let [h, ..t] = xs else { return 0 }
  h + t.len()
}
fn nums(strs: [str]): [int]! = strs.map(s => int.parse(s))?
fn isqrt(n: int): int
  requires n >= 0
  ensures result * result <= n
{ ?? }
fn deposit(a: var Point, d: float)
  ensures a.x == old(a.x) + d
{
  a.x += d
}
async fn get(url: str): str! uses net {
  var c = net.tcp(url, 80)?
  c.close()
  url
}
async fn both(u1: str, u2: str): [str!]! uses net {
  let page = await get(u1)?
  let (a, b) = await (get(u1), get(u2))
  let all = await [u1, u2].map(u => get(u))
  [a, b] + all + [page]
}
test "isqrt" { assert isqrt(17) == 4 }
fn main(args: [str]): int! uses fs {
  var n: int = 0
  n += 1
  let p = Point { x: 1.0, y: 2.0 }
  let q = Point { x: 3.0, ..p }
  let (x, y) = (1.0, 2.0)
  let r = Point { x, y }
  let c = load("a.toml") else e => default()
  let k = int.parse("12") else 0
  let name = find([User { id: 1, name: "ann" }], 1)?.name else "nobody"
  let v = loop { if k > 0 { break 42 } }
  for i, (a, b) in [(1, 2)] { print(i + a + b) }
  print("{c.name} {k} {name} {v} {area(Circle(2.0)) + q.x + r.y} {fib(10)} {len([1, 2], 0)} {grade(95)} {core.str(1)}")
  print(parse("x") is err(Eof))
  0
}
