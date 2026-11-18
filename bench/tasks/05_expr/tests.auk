test "hidden eval_expr" {
  let e = Add(Num(2), Mul(Var("x"), Neg(Num(3))))
  assert eval_expr(e, {"x": 4}) == some(-10)
  assert eval_expr(e, {"x": 0}) == some(2)
  assert eval_expr(Var("y"), {}) == none
  assert eval_expr(Add(Num(1), Var("z")), {"x": 1}) == none
  assert eval_expr(Mul(Var("z"), Num(0)), {}) == none
  assert eval_expr(Num(-7), {}) == some(-7)
  assert eval_expr(Neg(Neg(Var("a"))), {"a": 5}) == some(5)
  assert eval_expr(Mul(Add(Var("a"), Var("b")), Var("a")), {"a": 3, "b": -1}) == some(6)
}

test "hidden render" {
  assert render(Add(Num(2), Mul(Var("x"), Neg(Num(3))))) == "(2 + (x * -3))"
  assert render(Num(-5)) == "-5"
  assert render(Num(0)) == "0"
  assert render(Var("abc")) == "abc"
  assert render(Neg(Neg(Var("a")))) == "--a"
  assert render(Mul(Add(Num(1), Num(2)), Neg(Add(Var("y"), Num(10))))) == "((1 + 2) * -(y + 10))"
}
