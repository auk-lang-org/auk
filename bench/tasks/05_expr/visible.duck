test "visible expr" {
  let e = Add(Num(2), Mul(Var("x"), Neg(Num(3))))
  assert eval_expr(e, {"x": 4}) == some(-10)
  assert eval_expr(Var("y"), {}) == none
  assert render(e) == "(2 + (x * -3))"
}
