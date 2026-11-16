test "visible calc" {
  assert tokenize("12+(3)")? == [Num(12), Op('+'), LParen, Num(3), RParen]
  assert calc("1 + 2 * 3")? == 7
  assert calc("-7 / 2")? == -3
  assert calc("1 +") is err(Syntax)
  assert calc("2 $ 3") is err(BadToken('$'))
  assert calc("1 / 0") is err(DivZero)
}
