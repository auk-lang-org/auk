def rle_encode(s: str) -> str:
    out = []
    i = 0
    while i < len(s):
        j = i
        while j < len(s) and s[j] == s[i]:
            j += 1
        out.append(s[i] + (str(j - i) if j - i > 1 else ""))
        i = j
    return "".join(out)


def rle_decode(s: str) -> str:
    if s and s[0] in "0123456789":
        raise LeadingDigit()
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        i += 1
        j = i
        while j < len(s) and s[j] in "0123456789":
            j += 1
        if j > i:
            n = int(s[i:j])
            if n == 0:
                raise ZeroCount()
        else:
            n = 1
        out.append(c * n)
        i = j
    return "".join(out)
