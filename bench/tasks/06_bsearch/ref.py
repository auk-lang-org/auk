def bsearch(xs: List[int], target: int) -> Optional[int]:
    lo, hi = 0, len(xs)
    while lo < hi:
        mid = (lo + hi) // 2
        if xs[mid] < target:
            lo = mid + 1
        else:
            hi = mid
    return lo if lo < len(xs) and xs[lo] == target else None
