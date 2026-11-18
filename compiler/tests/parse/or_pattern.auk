enum Tok { LParen, RParen, Ident(s: str), Kw(s: str), Num(n: int) }

fn closes(t: Tok): bool = match t {
  RParen | LParen => true
  _ => false
}

fn text(t: Tok): str = match t {
  Ident(s) | Kw(s) when s.len() > 1 => s
  Num(0) | Num(1) |
    Num(2) => "small"
  (LParen) | _ => "?"
}

fn one_line(n: int): int = match n { 0 | 1 => 1, _ => n }
