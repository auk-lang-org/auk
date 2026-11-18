fn split_csv(line: str): [str]!CsvErr {
  let cs = line.chars()
  var fields: [str] = []
  var i = 0
  loop {
    var f: [char] = []
    if i < cs.len() && cs[i] == '"' {
      i += 1
      loop {
        if i >= cs.len() { fail(Unterminated) }
        if cs[i] == '"' {
          if i + 1 < cs.len() && cs[i + 1] == '"' {
            f.push('"')
            i += 2
          } else {
            i += 1
            break
          }
        } else {
          f.push(cs[i])
          i += 1
        }
      }
      if i < cs.len() && cs[i] != ',' { fail(JunkAfterQuote(i)) }
    } else {
      while i < cs.len() && cs[i] != ',' {
        f.push(cs[i])
        i += 1
      }
    }
    fields.push(str(f))
    if i >= cs.len() { break }
    i += 1
  }
  fields
}
