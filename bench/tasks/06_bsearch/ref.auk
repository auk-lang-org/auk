fn bsearch(xs: [int], target: int): int? {
  var lo = 0
  var hi = xs.len()
  while lo < hi {
    let mid = (lo + hi) / 2
    if xs[mid] < target { lo = mid + 1 } else { hi = mid }
  }
  if lo < xs.len() && xs[lo] == target { some(lo) } else { none }
}
