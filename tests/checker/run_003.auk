enum Tok { Ident(s: str), LParen, Fn }
struct Token { tok: Tok, doc: str }
struct P { toks: [Token], pos: int, name: str }

fn peek(p: P): Tok = p.toks[p.pos].tok
fn at(p: P, t: Tok): bool = p.peek() == t
fn kind(p: P): str {
  match p.toks[p.pos].tok {
    Ident(s) => "ident {s}"
    LParen => "("
    _ => "other"
  }
}
fn clear(p: var P): str {
  p.toks = []
  p.name = "gone" + "!"
  "cleared"
}
fn show2(a: str, p: var P): str {
  p.name = "new" + "!"
  p.toks = []
  a
}

fn main() {
  let toks = [Token { tok: Ident("x" + "y"), doc: "d" + "1" }, Token { tok: Tok.LParen, doc: "" }, Token { tok: Tok.Fn, doc: "" }]
  var p = P { toks: toks, pos: 0, name: "p" + "1" }
  print("{p.kind()} {p.at(Tok.LParen)} {p.toks[0].tok == Ident("xy")} {p.toks[0].doc}")
  p.pos = 1
  print("{p.kind()} {p.at(Tok.LParen)} {p.toks[1].tok != Tok.Fn} {p.toks[p.pos].tok is LParen}")
  // the element is read before a call that changes the list: still the old value
  var q = p
  q.pos = 0
  print(q.toks[0].doc + q.clear())
  print("{q.toks.len()} {q.name}")
  // a field passed next to `&` of the same variable
  var r = p
  print(show2(r.name, &r))
  print(show2(r.toks.len().str(), &r))
  var s = p
  print(show2(s.toks[0].doc, &s))
  print(p.toks.map(t => t.doc).join(","))
}
