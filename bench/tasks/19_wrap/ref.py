def wrap(text: str, width: int) -> List[str]:
    words = [w[i:i + width] for w in text.split() for i in range(0, len(w), width)]
    lines: List[str] = []
    cur = ""
    for w in words:
        if not cur:
            cur = w
        elif len(cur) + 1 + len(w) <= width:
            cur += " " + w
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines
