/// RFC 4180 CSV: text <-> rows of fields, plus header-keyed rows. Pure: no effects.

/// Why CSV text could not be read. Line and column are 1-based (a quoted field may span lines).
pub enum CsvErr {
  Unclosed(line: int, col: int),                 // a quoted field never closes (points at its opening quote)
  StrayQuote(line: int, col: int),               // a `"` inside an unquoted field, e.g. `a"b`
  AfterQuote(found: char, line: int, col: int),  // text after a closing quote, e.g. `"a"b`
  Ragged(row: int, want: int, got: int),         // header-keyed rows: a row with the wrong field count
  DupHeader(name: str),                          // header-keyed rows: the same column name twice
}

/// A one-line description of an error, e.g. `1:3: quoted field is never closed`.
pub fn message(e: CsvErr): str
fn message(Unclosed(l, k)): str = "{l}:{k}: quoted field is never closed"
fn message(StrayQuote(l, k)): str =
  "{l}:{k}: quote inside an unquoted field (quote the whole field and double it)"
fn message(AfterQuote(c, l, k)): str = "{l}:{k}: unexpected '{c}' after closing quote"
fn message(Ragged(r, w, g)): str = "row {r}: expected {w} fields, got {g}"
fn message(DupHeader(n)): str = "duplicate column '{n}'"

// ---- reader: one pass over the chars, a field at a time ----

/// Parse CSV text (RFC 4180) into rows of fields. Fields are separated by `,`; rows end in CRLF,
/// LF or a lone CR, and the last row's line break is optional. A field in double quotes may hold
/// `,`, line breaks and doubled quotes (`"say ""hi"""` reads as `say "hi"`). Spaces are kept.
/// A blank line is a row with one empty field; rows may differ in length.
pub fn parse(s: str): [[str]]!CsvErr {
  let cs = s.chars()
  let n = cs.len()
  var rows: [[str]] = []
  var row: [str] = []
  var i = 0                       // always at the start of a field here
  while i < n || row.len() > 0 {  // `a,` ends with an empty field
    if i < n && cs[i] == '"' {
      // quoted: `""` is a literal quote, a lone `"` closes, anything else (even a newline) is kept
      let q = i
      var doubled = false
      i += 1
      loop {
        if i >= n {
          let (l, k) = pos(cs, q)
          fail(Unclosed(l, k))
        }
        if cs[i] != '"' {
          i += 1
        } else if i + 1 < n && cs[i + 1] == '"' {
          doubled = true
          i += 2
        } else {
          break
        }
      }
      let f = str(cs[q + 1..i])
      row.push(if doubled { f.replace("\"\"", "\"") } else { f })
      i += 1
      if i < n && cs[i] != ',' && cs[i] != '\n' && cs[i] != '\r' {
        let (l, k) = pos(cs, i)
        fail(AfterQuote(cs[i], l, k))
      }
    } else {
      let a = i
      while i < n && cs[i] != ',' && cs[i] != '\n' && cs[i] != '\r' {
        if cs[i] == '"' {
          let (l, k) = pos(cs, i)
          fail(StrayQuote(l, k))
        }
        i += 1
      }
      row.push(if i > a { str(cs[a..i]) } else { "" })
    }
    // what ended the field: a comma, a line break or the end of the input
    if i < n && cs[i] == ',' {
      i += 1
    } else {
      i += if i + 1 < n && cs[i] == '\r' && cs[i + 1] == '\n' { 2 } else { 1 }
      rows.push(row)
      row = []
    }
  }
  rows
}

// 1-based (line, col) of index i, counting CRLF, LF and lone CR as one line break each.
// Only computed on the error path.
fn pos(cs: [char], i: int): (int, int) {
  var (line, col) = (1, 1)
  for j in 0..i {
    let crlf = cs[j] == '\r' && j + 1 < cs.len() && cs[j + 1] == '\n'
    if cs[j] == '\n' || (cs[j] == '\r' && !crlf) {
      line += 1
      col = 1
    } else {
      col += 1
    }
  }
  (line, col)
}

// ---- header-keyed rows ----

/// Parse CSV whose first row is a header into one map per row, keyed by column name.
/// Blank lines are skipped. A row whose field count differs from the header's is a `Ragged`
/// error (`row` counts parsed rows, header = 1); a repeated column name is a `DupHeader` error.
/// Empty input gives `[]`.
pub fn records(s: str): [{str: str}]!CsvErr {
  let [header, ..body] = parse(s)? else return []
  var seen: Set<str> = set([])
  for h in header {
    if seen.contains(h) { fail(DupHeader(h)) }
    seen.insert(h)
  }
  let w = header.len()
  var out: [{str: str}] = []
  for n, r in body {
    if r.len() == 1 && r[0] == "" { continue }
    if r.len() != w { fail(Ragged(n + 2, w, r.len())) }
    var m: {str: str} = {}
    for j, h in header { m[h] = r[j] }
    out.push(m)
  }
  out
}

// ---- writer ----

/// Render rows as CSV text: fields joined by `,`, every row ending in CRLF (RFC 4180). A field is
/// quoted only when it contains `,`, `"`, CR or LF, with inner quotes doubled. `parse(write(rows))`
/// gives back `rows`, except that an empty row `[]` reads back as `[""]`.
pub fn write(rows: [[str]]): str {
  var out = ""
  for r in rows {
    for j, f in r {
      if j > 0 { out += "," }
      out += cell(f)
    }
    out += "\r\n"
  }
  out
}

/// Render header-keyed rows: the header line, then each row's values in header order.
/// A key missing from a row writes an empty field; keys not in `header` are left out.
pub fn write_records(header: [str], recs: [{str: str}]): str {
  var out = write([header])
  for r in recs {
    for j, h in header {
      if j > 0 { out += "," }
      out += cell(r.get(h) else "")
    }
    out += "\r\n"
  }
  out
}

fn cell(f: str): str when needs_quotes(f) = "\"" + f.replace("\"", "\"\"") + "\""
fn cell(f: str): str = f

fn needs_quotes(f: str): bool =
  f.contains(',') || f.contains('"') || f.contains('\r') || f.contains('\n')

// ---- to Value ----

/// Header-keyed rows as core `Value`s, so callers can `from_value` them into structs. Each row
/// becomes a `Map`, and each cell is typed by its text: `Bool` for exactly `true`/`false`, `Int`
/// for a canonical integer (`42`, `-7`; not `007` or `+5`), `Float` for a number with a `.` or
/// exponent (`1.5`, `2e3`), and `Str` for everything else, including the empty string.
/// Caveat: a text column of digits (a zip code like `12345`) becomes `Int`.
pub fn to_values(recs: [{str: str}]): [Value] = recs.map(r => Map(cells(r)))

fn cells(r: {str: str}): {str: Value} {
  var m: {str: Value} = {}
  for k, v in r { m[k] = scalar(v) }
  m
}

fn scalar("true"): Value = Bool(true)
fn scalar("false"): Value = Bool(false)
fn scalar(""): Value = Str("")
fn scalar(s: str): Value {
  // every int and float starts with a digit, a sign or a `.`; anything else is text
  let c = s[0]
  if !(c.is_digit() || c == '-' || c == '+' || c == '.') { return Str(s) }
  if c != '+' && c != '.' && canonical_int(s) { return Int(int.parse(s)!) }
  if looks_float(s) { return Float(float.parse(s) else return Str(s)) }
  Str(s)
}

// an int that prints back as the same text (so `007`, `+5`, `-0`, ` 1` stay strings)
fn canonical_int(s: str): bool {
  let n = int.parse(s) else return false
  "{n}" == s
}

// has a `.` or exponent (so `inf`, `nan` stay strings; `float.parse` then needs a digit)
fn looks_float(s: str): bool = s.contains('.') || s.contains('e') || s.contains('E')

/// Parse header-keyed CSV straight into typed rows via `to_values` and the derived `from_value`;
/// the row type comes from the annotation: `let items: [Item] = csv.decode(s)?`.
pub fn decode<T: Data>(s: str): [T]! = to_values(records(s)?).map(v => from_value(v))?

// ---- tests ----

test "simple rows" {
  assert parse("a,b,c\n1,2,3\n")? == [["a", "b", "c"], ["1", "2", "3"]]
  assert parse("a,b\n1,2")? == [["a", "b"], ["1", "2"]]          // no final line break
  assert parse("a,b\r\n1,2\r\n")? == [["a", "b"], ["1", "2"]]    // CRLF
  assert parse("a\rb\r")? == [["a"], ["b"]]                      // lone CR
  assert parse("a\r\nb\nc\rd")? == [["a"], ["b"], ["c"], ["d"]]  // mixed
  assert parse("one")? == [["one"]]
  assert parse(" a , b ")? == [[" a ", " b "]]  // spaces are data
  assert parse("é,😀\n")? == [["é", "😀"]]
  assert parse("a,b\n1,2,3\n4\n")? == [["a", "b"], ["1", "2", "3"], ["4"]]  // ragged is fine here
}

test "empty fields and lines" {
  assert parse("")? == []
  assert parse("\n")? == [[""]]
  assert parse("\r\n")? == [[""]]
  assert parse(",")? == [["", ""]]
  assert parse(",,\n")? == [["", "", ""]]
  assert parse("a,")? == [["a", ""]]
  assert parse("a,\r\n")? == [["a", ""]]
  assert parse(",a")? == [["", "a"]]
  assert parse("a\n\nb\n")? == [["a"], [""], ["b"]]  // a blank line is one empty field
  assert parse("a\n\n")? == [["a"], [""]]
}

test "quoted fields" {
  assert parse("\"a,b\",c")? == [["a,b", "c"]]
  assert parse("\"say \"\"hi\"\"\"")? == [["say \"hi\""]]
  assert parse("\"\"")? == [[""]]
  assert parse("\"\",\"\"")? == [["", ""]]
  assert parse("a,\"\"")? == [["a", ""]]
  assert parse("\"\"\"\"")? == [["\""]]  // just a quote
  assert parse("\"line1\nline2\",x\n")? == [["line1\nline2", "x"]]
  assert parse("\"crlf\r\ninside\"\r\nnext")? == [["crlf\r\ninside"], ["next"]]
  assert parse("\" padded \"")? == [[" padded "]]
  assert parse("\"a\"\r\n\"b\"")? == [["a"], ["b"]]
  assert parse("\",\n\"\"\",\"\"")? == [[",\n\"", ""]]
}

test "errors" {
  assert parse("\"abc") is err(Unclosed(1, 1))
  assert parse("a,\"b\nc") is err(Unclosed(1, 3))
  assert parse("x\ny,\"oops\"\"") is err(Unclosed(2, 3))  // `""` is a literal quote
  assert parse("a\"b") is err(StrayQuote(1, 2))
  assert parse("ab,cd\"") is err(StrayQuote(1, 6))
  assert parse("\"a\"b") is err(AfterQuote('b', 1, 4))
  assert parse("\"a\" ,b") is err(AfterQuote(' ', 1, 4))
  assert parse("ok\r\n\"a\"x") is err(AfterQuote('x', 2, 4))  // CRLF counts as one line
  assert parse("\"two\nlines\"!") is err(AfterQuote('!', 2, 7))
  assert message(Unclosed(1, 3)) == "1:3: quoted field is never closed"
  assert message(Ragged(3, 2, 1)) == "row 3: expected 2 fields, got 1"
}

test "long input does not overflow" {
  var lines: [str] = []
  for i in 0..100_000 { lines.push("{i},\"x,{i}\"") }
  let rows = parse(lines.join("\r\n"))?
  assert rows.len() == 100_000
  assert rows[99_999] == ["99999", "x,99999"]
  let big = lines.join("")
  assert parse("\"" + big.replace("\"", "\"\"") + "\"")? == [[big]]
}

test "records" {
  let rs = records("name,qty\nnut,3\r\n\nbolt,\n")?
  assert rs == [{"name": "nut", "qty": "3"}, {"name": "bolt", "qty": ""}]
  assert records("")? == []
  assert records("a,b\n")? == []
  assert records("a,b\n1,2,3") is err(Ragged(2, 2, 3))
  assert records("a,b\n1,2\n3") is err(Ragged(3, 2, 1))
  assert records("a,b,a\n1,2,3") is err(DupHeader("a"))
  assert records("a,\"b") is err(Unclosed(1, 3))
  assert records("\"x,y\",z\n\"1\n2\",3")? == [{"x,y": "1\n2", "z": "3"}]
}

test "write" {
  assert write([]) == ""
  assert write([["a", "b"], ["1", "2"]]) == "a,b\r\n1,2\r\n"
  assert write([["a,b", "say \"hi\"", "two\nlines", "cr\r", "plain"]]) ==
    "\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\",\"cr\r\",plain\r\n"
  assert write([[" spaced ", ""]]) == " spaced ,\r\n"  // spaces and empties: no quotes
  assert write([[""]]) == "\r\n"
  assert write([["é😀"]]) == "é😀\r\n"
}

test "round trips" {
  let tables = [
    [["a", "b"], ["1", "2"]],
    [["", ""], [""], ["x"]],
    [["a,b", "\"", "\"\"", "line\nbreak", "cr\r\nlf", " sp "]],
    [["é", "😀,", ""]],
  ]
  for t in tables {
    assert parse(write(t))? == t
  }
}

test "write_records" {
  let rs = [{"name": "nut", "qty": "3"}, {"name": "bolt, big"}]
  assert write_records(["name", "qty"], rs) == "name,qty\r\nnut,3\r\n\"bolt, big\",\r\n"
  assert records(write_records(["name", "qty"], rs))? ==
    [{"name": "nut", "qty": "3"}, {"name": "bolt, big", "qty": ""}]
  assert write_records(["a"], []) == "a\r\n"
}

test "to_values" {
  let vs = to_values(
    records("s,i,neg,f,e,b,z,plus,empty,word\nx,42,-7,1.5,2e3,true,007,+5,,inf\n")?,
  )
  assert vs == [
    Map({
      "s": Str("x"),
      "i": Int(42),
      "neg": Int(-7),
      "f": Float(1.5),
      "e": Float(2000.0),
      "b": Bool(true),
      "z": Str("007"),
      "plus": Str("+5"),
      "empty": Str(""),
      "word": Str("inf"),
    }),
  ]
  assert to_values([]) == []
  assert to_values([{"v": "1.2.3"}, {"v": "TRUE"}, {"v": "1e"}]) ==
    [Map({"v": Str("1.2.3")}), Map({"v": Str("TRUE")}), Map({"v": Str("1e")})]
}

// used by the decode tests
struct Item { name: str, qty: int, price: float, stocked: bool }

test "decode" {
  let items: [Item] = decode("name,qty,price,stocked\nnut,3,0.25,true\r\nbolt,10,1.5,false\n")?
  assert items == [
    Item { name: "nut", qty: 3, price: 0.25, stocked: true },
    Item { name: "bolt", qty: 10, price: 1.5, stocked: false },
  ]
  let empty: [Item] = decode("name,qty,price,stocked\n")?
  assert empty == []
  let bad: [Item]! = decode("name,qty,price,stocked\nnut,many,0.25,true\n")
  assert bad is err(_)
  let ragged: [Item]! = decode("name,qty\nnut\n")
  assert ragged is err(_)
}
