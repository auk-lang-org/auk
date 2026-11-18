enum Tok { LParen, RParen, LBracket, RBracket, Ident(s: str), Kw(s: str), Num(n: int), Eof }
enum Shape { Circle(r: float), Square(side: float), Rect(w: float, h: float), Dot }
struct P { name: str, age: int }

fn closes(t: Tok): bool = match t {
  RParen | RBracket => true
  _ => false
}

fn text(t: Tok): str = match t {
  Ident(s) | Kw(s) => s
  Num(n) => "{n}"
  LParen | RParen | LBracket |
    RBracket => "bracket"
  Eof => "eof"
}

fn size(s: Shape): float = match s {
  Circle(x) | Square(x) | Rect(x, _) => x
  Dot => 0.0
}

fn small(n: int): str = match n { 0 | 1 | 2 => "small", _ => "big" }

fn names(xs: [P]): str = match xs {
  [P { name, .. }] | [_, P { name, .. }] => name
  _ => "?"
}

fn list_rest(xs: [str]): [str] = match xs {
  ["a", ..rest] | ["b", ..rest] => rest
  _ => []
}

fn opt(x: int?): int = match x {
  some(0) | none => -1
  some(n) => n
}

fn guarded(t: Tok): str = match t {
  Ident(s) | Kw(s) when s.len() > 2 => "long {s}"
  _ => "other"
}

fn main() {
  print("{closes(RParen)} {closes(LParen)} {closes(RBracket)}")
  print("{text(Ident("x"))} {text(Kw("fn"))} {text(Num(3))} {text(LBracket)} {text(Eof)}")
  print("{size(Circle(1.0))} {size(Square(2.0))} {size(Rect(3.0, 4.0))} {size(Dot)}")
  print("{small(1)} {small(5)}")
  print(names([P { name: "ann", age: 1 }]))
  print(names([P { name: "ann", age: 1 }, P { name: "bob", age: 2 }]))
  print("{list_rest(["a", "x", "y"])} {list_rest(["b", "z"])} {list_rest(["c"])}")
  print("{opt(some(0))} {opt(none)} {opt(some(4))}")
  print("{guarded(Ident("abc"))} {guarded(Kw("ab"))} {guarded(Num(1))}")
}
