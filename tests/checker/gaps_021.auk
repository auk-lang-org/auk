fn forever(n: int): int = 1 + forever(n + 1)
test "deep" { assert forever(0) == 1 }
test "fine" { assert 1 == 1 }
