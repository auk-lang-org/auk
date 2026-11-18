fn positive(s: str): bool when (int.parse(s) else 0) > 0 = true
fn positive(_: str): bool = false
