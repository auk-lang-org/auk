fn rle_encode(s: str): str {
  let cs = s.chars()
  var out = ""
  var i = 0
  while i < cs.len() {
    var j = i
    while j < cs.len() && cs[j] == cs[i] { j += 1 }
    out = out + str(cs[i])
    if j - i > 1 { out = out + str(j - i) }
    i = j
  }
  out
}

fn rle_decode(s: str): str!RleErr {
  let cs = s.chars()
  if cs.len() > 0 && cs[0].is_digit() { fail(LeadingDigit) }
  var out = ""
  var i = 0
  while i < cs.len() {
    let c = cs[i]
    i += 1
    var n = 0
    var has = false
    while i < cs.len() && cs[i].is_digit() {
      n = n * 10 + (int(cs[i]) - int('0'))
      has = true
      i += 1
    }
    if has && n == 0 { fail(ZeroCount) }
    out = out + str(c).repeat(if has { n } else { 1 })
  }
  out
}
