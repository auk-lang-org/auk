fn spiral(m: [[int]]): [int] {
  var out: [int] = []
  if m.len() == 0 { return out }
  var top = 0
  var bottom = m.len() - 1
  var left = 0
  var right = m[0].len() - 1
  while top <= bottom && left <= right {
    for c in left..=right { out.push(m[top][c]) }
    for r in top + 1..=bottom { out.push(m[r][right]) }
    if top < bottom {
      for c in (left..right).reverse() { out.push(m[bottom][c]) }
    }
    if left < right {
      for r in (top + 1..bottom).reverse() { out.push(m[r][left]) }
    }
    top += 1
    bottom -= 1
    left += 1
    right -= 1
  }
  out
}
