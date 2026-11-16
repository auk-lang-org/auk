def to_base(n: int, base: int) -> str:
    assert 2 <= base <= 36
    if n == 0:
        return "0"
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    m, out = abs(n), []
    while m:
        out.append(digits[m % base])
        m //= base
    return ("-" if n < 0 else "") + "".join(reversed(out))
