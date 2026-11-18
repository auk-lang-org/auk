fn fact(0): int = 1
fn fact(n: int): int = n * fact(n - 1)
fn deep(n: int): int = deep(n + 1) + 1
test "good" { assert fact(3) == 6 }
test "bad" { assert fact(3) == 7 }
test "overflow" { assert deep(0) == 1 }
