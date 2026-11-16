def spiral(m: List[List[int]]) -> List[int]:
    out: List[int] = []
    if not m:
        return out
    top, bottom, left, right = 0, len(m) - 1, 0, len(m[0]) - 1
    while top <= bottom and left <= right:
        out += [m[top][c] for c in range(left, right + 1)]
        out += [m[r][right] for r in range(top + 1, bottom + 1)]
        if top < bottom:
            out += [m[bottom][c] for c in range(right - 1, left - 1, -1)]
        if left < right:
            out += [m[r][left] for r in range(bottom - 1, top, -1)]
        top, bottom, left, right = top + 1, bottom - 1, left + 1, right - 1
    return out
