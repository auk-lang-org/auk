NUMERALS = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
DIGITS = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}


def to_roman(n: int) -> str:
    assert 1 <= n <= 3999
    out = ""
    for v, s in NUMERALS:
        while n >= v:
            out += s
            n -= v
    return out


def from_roman(s: str) -> Optional[int]:
    total = 0
    for i, c in enumerate(s):
        if c not in DIGITS:
            return None
        v = DIGITS[c]
        if i + 1 < len(s) and DIGITS.get(s[i + 1], 0) > v:
            total -= v
        else:
            total += v
    if not 1 <= total <= 3999 or to_roman(total) != s:
        return None
    return total
