fn parse_kv(s: str): {str: int}!KvErr {
  var m: {str: int} = {}
  for i, seg in s.split(";") {
    if seg.trim() == "" { continue }
    let eq = seg.find("=") else fail(MissingEq(i))
    let key = seg[0..eq].trim()
    if key == "" { fail(EmptyKey(i)) }
    let v = int.parse(seg[eq + 1..seg.len()].trim()) else fail(BadValue(key))
    m[key] = v
  }
  m
}
