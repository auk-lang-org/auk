fn eval_expr(e: Expr, vars: {str: int}): int? = match e {
  Num(n) => n
  Var(name) => vars.get(name)
  Add(a, b) => eval_expr(a, vars)? + eval_expr(b, vars)?
  Mul(a, b) => eval_expr(a, vars)? * eval_expr(b, vars)?
  Neg(x) => -eval_expr(x, vars)?
}

fn render(e: Expr): str = match e {
  Num(n) => str(n)
  Var(name) => name
  Add(a, b) => "({render(a)} + {render(b)})"
  Mul(a, b) => "({render(a)} * {render(b)})"
  Neg(x) => "-{render(x)}"
}
