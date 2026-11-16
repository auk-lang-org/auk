def eval_expr(e: Expr, vars: Dict[str, int]) -> Optional[int]:
    if isinstance(e, Num):
        return e.n
    if isinstance(e, Var):
        return vars.get(e.name)
    if isinstance(e, Neg):
        v = eval_expr(e.e, vars)
        return None if v is None else -v
    a = eval_expr(e.a, vars)
    if a is None:
        return None
    b = eval_expr(e.b, vars)
    if b is None:
        return None
    return a + b if isinstance(e, Add) else a * b


def render(e: Expr) -> str:
    if isinstance(e, Num):
        return str(e.n)
    if isinstance(e, Var):
        return e.name
    if isinstance(e, Neg):
        return "-" + render(e.e)
    op = "+" if isinstance(e, Add) else "*"
    return f"({render(e.a)} {op} {render(e.b)})"
