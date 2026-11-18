enum Expr { Num(n: int), Var(name: str), Add(a: Expr, b: Expr), Mul(a: Expr, b: Expr), Neg(e: Expr) }
