fn merge(xs: [(int, int)]): [(int, int)] {
  var out: [(int, int)] = []
  for (s, e) in xs.sort() {
    if out.len() > 0 && s <= out[out.len() - 1].1 {
      let (ls, le) = out[out.len() - 1]
      out[out.len() - 1] = (ls, if e > le { e } else { le })
    } else {
      out.push((s, e))
    }
  }
  out
}
