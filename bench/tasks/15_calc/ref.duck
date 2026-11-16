fn tokenize(s: str): [Tok]!CalcErr {
  let cs = s.chars()
  var ts: [Tok] = []
  var i = 0
  while i < cs.len() {
    let c = cs[i]
    if c.is_digit() {
      var n = 0
      while i < cs.len() && cs[i].is_digit() {
        n = n * 10 + (int(cs[i]) - int('0'))
        i += 1
      }
      ts.push(Num(n))
      continue
    }
    if c == '+' || c == '-' || c == '*' || c == '/' { ts.push(Op(c)) }
    else if c == '(' { ts.push(LParen) }
    else if c == ')' { ts.push(RParen) }
    else if c != ' ' { fail(BadToken(c)) }
    i += 1
  }
  ts
}

fn parse_expr(ts: [Tok], pos: var int): int!CalcErr {
  var v = parse_term(ts, &pos)?
  loop {
    match ts.get(pos) {
      some(Op('+')) => {
        pos += 1
        v = v + parse_term(ts, &pos)?
      }
      some(Op('-')) => {
        pos += 1
        v = v - parse_term(ts, &pos)?
      }
      _ => break
    }
  }
  v
}

fn parse_term(ts: [Tok], pos: var int): int!CalcErr {
  var v = parse_factor(ts, &pos)?
  loop {
    match ts.get(pos) {
      some(Op('*')) => {
        pos += 1
        v = v * parse_factor(ts, &pos)?
      }
      some(Op('/')) => {
        pos += 1
        let d = parse_factor(ts, &pos)?
        if d == 0 { fail(DivZero) }
        v = v / d
      }
      _ => break
    }
  }
  v
}

fn parse_factor(ts: [Tok], pos: var int): int!CalcErr {
  match ts.get(pos) {
    some(Op('-')) => {
      pos += 1
      -parse_factor(ts, &pos)?
    }
    some(Num(n)) => {
      pos += 1
      n
    }
    some(LParen) => {
      pos += 1
      let v = parse_expr(ts, &pos)?
      if ts.get(pos) != some(RParen) { fail(Syntax) }
      pos += 1
      v
    }
    _ => fail(Syntax)
  }
}

fn calc(s: str): int!CalcErr {
  let ts = tokenize(s)?
  var pos = 0
  let v = parse_expr(ts, &pos)?
  if pos != ts.len() { fail(Syntax) }
  v
}
