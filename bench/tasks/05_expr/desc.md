An arithmetic expression tree with integer literals, variables, addition, multiplication and negation. Two functions:

`eval_expr(e, vars)` evaluates the expression, looking variables up in `vars`. If any variable that is evaluated is missing from `vars`, the result is missing (none / None).

`render(e)` prints the expression: a number as its decimal digits (a negative number with a leading `-`), a variable as its name, `Add` as `(a + b)`, `Mul` as `(a * b)`, and `Neg` as `-` directly followed by its operand. Example: `Add(Num(2), Mul(Var("x"), Neg(Num(3))))` renders as `(2 + (x * -3))`.
