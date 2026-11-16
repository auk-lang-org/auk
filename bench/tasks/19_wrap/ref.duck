fn wrap(text: str, width: int): [str]
  requires width >= 1
{
  var words: [str] = []
  for w in text.split() {
    var i = 0
    while i < w.len() {
      let end = if i + width < w.len() { i + width } else { w.len() }
      words.push(w[i..end])
      i = end
    }
  }
  var lines: [str] = []
  var cur = ""
  for w in words {
    if cur == "" { cur = w }
    else if cur.len() + 1 + w.len() <= width { cur = cur + " " + w }
    else {
      lines.push(cur)
      cur = w
    }
  }
  if cur != "" { lines.push(cur) }
  lines
}
