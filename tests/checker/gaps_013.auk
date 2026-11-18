struct Parser { toks: [str], pos: int, depth: int }
enum Fail { Bad(m: str) }

fn peek(p: Parser): str = p.toks.get(p.pos) else ""
fn next(p: var Parser): str {
  let t = p.peek()
  p.pos += 1
  t
}

fn item(p: var Parser): str!Fail {
  let t = p.next()
  if t == "!" { fail(Bad("bang at {p.pos - 1}")) }
  t.upper()
}

/// `close`-terminated, comma-separated items, each parsed by `f`
fn list(p: var Parser, close: str, f: (var Parser) => str!Fail): [str]!Fail {
  var out: [str] = []
  while p.peek() != close && p.peek() != "" {
    out.push(f(&p)?)
    if p.peek() == "," { p.next() }
  }
  p.next()
  out
}

fn nested(p: var Parser, f: (var Parser) => str!Fail): str!Fail {
  p.depth += 1
  let r = f(&p)
  p.depth -= 1
  r
}

fn twice(n: var int, g: (var int, int) => ()) {
  g(&n, 1)
  g(&n, 2)
}

fn main() {
  var p = Parser { toks: ["a", ",", "b", ",", "c", ")", "z"], pos: 0, depth: 0 }
  print(list(&p, ")", item))
  print(p.pos)
  var q = Parser { toks: ["x", "y", ")"], pos: 0, depth: 0 }
  print(list(&q, ")", r => "<{r.next()}>"))
  var s = Parser { toks: ["x", "!", ")"], pos: 0, depth: 0 }
  print(list(&s, ")", item) else e => ["{e}"])
  var u = Parser { toks: ["k"], pos: 0, depth: 3 }
  print(nested(&u, (r: var Parser) => "{r.depth}:{r.next()}"))
  print("{u.depth} {u.pos}")
  var n = 10
  twice(&n, (x, k) => { x += k })
  print(n)
  let h: (var int) => int = x => {
    x *= 2
    x
  }
  var m = 5
  print("{h(&m)} {m}")
  let fs: [(var int) => ()] = [x => { x += 1 }, x => { x *= 3 }]
  for f in fs { f(&m) }
  print(m)
}
