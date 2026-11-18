/// Calculator: lexer + recursive-descent parser + evaluator, all with clauses.

enum Tok { Num(v: float), Op(c: char), LParen, RParen }
enum Expr { Lit(v: float), Bin(op: char, l: Expr, r: Expr), Neg(e: Expr) }
enum CalcErr { BadChar(c: char), Unexpected(t: Tok?), DivZero }

// ---- lexer ----
fn lex(s: str): [Tok]!CalcErr = lex(s.chars(), [])

fn lex([], out: [Tok]): [Tok]!CalcErr = out
fn lex([' ', ..t]: [char], out: [Tok]): [Tok]!CalcErr = lex(t, out)
fn lex(['(', ..t]: [char], out: [Tok]): [Tok]!CalcErr = lex(t, out + [LParen])
fn lex([')', ..t]: [char], out: [Tok]): [Tok]!CalcErr = lex(t, out + [RParen])
fn lex([c, ..t]: [char], out: [Tok]): [Tok]!CalcErr when "+-*/".contains(c) = lex(t, out + [Op(c)])
fn lex([c, ..t]: [char], out: [Tok]): [Tok]!CalcErr when c.is_digit() {
  let digits = [c] + t.take_while(d => d.is_digit() || d == '.')
  let v = float.parse(str(digits)) else fail(BadChar(c))
  lex(t.skip(digits.len() - 1), out + [Num(v)])
}
fn lex([c, .._]: [char], _: [Tok]): [Tok]!CalcErr = fail(BadChar(c))

// ---- parser: each fn returns (expr, remaining tokens) ----
fn expr(ts: [Tok]): (Expr, [Tok])!CalcErr {
  var (l, rest) = term(ts)?
  loop {
    match rest {
      [Op(o), ..t] when o == '+' || o == '-' => {
        let (r, t2) = term(t)?
        l = Bin(o, l, r)
        rest = t2
      }
      _ => break (l, rest)
    }
  }
}

fn term(ts: [Tok]): (Expr, [Tok])!CalcErr {
  var (l, rest) = atom(ts)?
  loop {
    match rest {
      [Op(o), ..t] when o == '*' || o == '/' => {
        let (r, t2) = atom(t)?
        l = Bin(o, l, r)
        rest = t2
      }
      _ => break (l, rest)
    }
  }
}

fn atom([Num(v), ..t]: [Tok]): (Expr, [Tok])!CalcErr = (Lit(v), t)
fn atom([Op('-'), ..t]: [Tok]): (Expr, [Tok])!CalcErr {
  let (e, rest) = atom(t)?
  (Neg(e), rest)
}
fn atom([LParen, ..t]: [Tok]): (Expr, [Tok])!CalcErr {
  let (e, rest) = expr(t)?
  let [RParen, ..after] = rest else fail(Unexpected(rest.first()))
  (e, after)
}
fn atom(ts: [Tok]): (Expr, [Tok])!CalcErr = fail(Unexpected(ts.first()))

// ---- evaluator ----
fn eval(Lit(v)): float!CalcErr = v
fn eval(Neg(e)): float!CalcErr = -eval(e)?
fn eval(Bin(op, l, r)): float!CalcErr {
  let (a, b) = (eval(l)?, eval(r)?)
  match op {
    '+' => a + b
    '-' => a - b
    '*' => a * b
    _ when b == 0.0 => fail(DivZero)
    _ => a / b
  }
}

fn calc(s: str): float!CalcErr {
  let (e, rest) = expr(lex(s)?)?
  if rest.len() > 0 { fail(Unexpected(rest.first())) }
  eval(e)
}

test "calc" {
  assert calc("1 + 2 * 3")? == 7.0
  assert calc("-(4 - 6) / 2")? == 1.0
  assert calc("1 / 0") is err(DivZero)
}
