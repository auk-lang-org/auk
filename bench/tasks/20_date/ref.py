def is_valid_date(s: str) -> bool:
    if len(s) != 10 or s[4] != "-" or s[7] != "-":
        return False
    parts = (s[0:4], s[5:7], s[8:10])
    if not all(c in "0123456789" for p in parts for c in p):
        return False
    y, m, d = (int(p) for p in parts)
    if y < 1 or not 1 <= m <= 12 or d < 1:
        return False
    leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
    days = [31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return d <= days[m - 1]
