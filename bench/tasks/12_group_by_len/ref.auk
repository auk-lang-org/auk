fn group_by_len(words: [str]): {int: [str]} {
  var groups: {int: [str]} = {}
  for w in words {
    var g = groups.get(w.len()) else []
    if !g.contains(w) { g.push(w) }
    groups[w.len()] = g
  }
  var out: {int: [str]} = {}
  for k in groups.keys().sort() { out[k] = groups[k] }
  out
}
