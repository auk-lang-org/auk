test "hidden tokenize" {
  assert tokenize("12+(3)")? == [Num(12), Op('+'), LParen, Num(3), RParen]
  assert tokenize("")? == []
  assert tokenize(" 7 * 08 / -1 ")? == [Num(7), Op('*'), Num(8), Op('/'), Op('-'), Num(1)]
  assert tokenize("1 x") is err(BadToken('x'))
  assert tokenize("1.5") is err(BadToken('.'))
}

test "hidden calc values" {
  assert calc("1 + 2 * 3")? == 7
  assert calc("(1 + 2) * 3")? == 9
  assert calc("10 / 3")? == 3
  assert calc("-7 / 2")? == -3
  assert calc("7 / -2")? == -3
  assert calc("-7 / -2")? == 3
  assert calc("2 - 3 - 4")? == -5
  assert calc("8 / 2 / 2")? == 2
  assert calc("--3")? == 3
  assert calc("-(2+3)*2")? == -10
  assert calc("2*-3")? == -6
  assert calc("42")? == 42
  assert calc(" ( ( 5 ) ) ")? == 5
  assert calc("100 - 4 * (3 + 2) / 6")? == 97
}

test "hidden calc errors" {
  assert calc("1 +") is err(Syntax)
  assert calc("") is err(Syntax)
  assert calc("(1") is err(Syntax)
  assert calc("1)") is err(Syntax)
  assert calc("1 2") is err(Syntax)
  assert calc("()") is err(Syntax)
  assert calc("* 2") is err(Syntax)
  assert calc("2 $ 3") is err(BadToken('$'))
  assert calc("a+(") is err(BadToken('a'))
  assert calc("(1 + 2 x") is err(BadToken('x'))
  assert calc("1 / 0") is err(DivZero)
  assert calc("1 / (2 - 2)") is err(DivZero)
  assert calc("0 / 5")? == 0
}
