/// XML 1.0 text <-> an element tree. Pure: no effects.

/// An element: its tag name (any prefix kept, e.g. `soap:Body`), its attributes in document
/// order, and its content.
pub struct Element { name: str, attrs: {str: str}, children: [Node] }

/// A piece of an element's content. CDATA sections become `Text`; comments and processing
/// instructions are dropped.
pub enum Node { Elem(e: Element), Text(s: str) }

/// Why `parse` failed. Every variant carries the 1-based line and column (counted in chars).
pub enum XmlErr {
  Syntax(why: str, line: int, col: int),
  Eof(want: str, line: int, col: int),                   // the text ended; `want` is what was needed
  Mismatch(open: str, close: str, line: int, col: int),  // `</close>` where `</open>` was due
  BadEntity(text: str, line: int, col: int),             // e.g. `&nbsp;`, `&#0;`, a bare `&`
  DuplicateAttr(name: str, line: int, col: int),
  TooDeep(line: int, col: int),  // elements nested deeper than MAX_DEPTH
}

/// The deepest nesting `parse` accepts; deeper input is a `TooDeep` error, not a stack overflow.
imprint MAX_DEPTH = 512

/// A one-line description of a parse error, e.g. `3:5: </b> closes <a>`.
pub fn message(e: XmlErr): str
fn message(Syntax(w, l, k)): str = "{l}:{k}: {w}"
fn message(Eof(w, l, k)): str = "{l}:{k}: unexpected end of input (expected {w})"
fn message(Mismatch(o, c, l, k)): str = "{l}:{k}: </{c}> closes <{o}>"
fn message(BadEntity(t, l, k)): str = "{l}:{k}: unknown or malformed entity '{t}'"
fn message(DuplicateAttr(n, l, k)): str = "{l}:{k}: attribute '{n}' is repeated"
fn message(TooDeep(l, k)): str = "{l}:{k}: nested deeper than {MAX_DEPTH}"

// ---- querying ----

/// The value of attribute `k`, if present.
pub fn attr(e: Element, k: str): str? = e.attrs.get(k)

/// The child elements, in order (text skipped).
pub fn elements(e: Element): [Element] {
  var out: [Element] = []
  for n in e.children {
    match n {
      Elem(c) => out.push(c)
      Text(_) => {}
    }
  }
  out
}

/// The first child element named `name`.
pub fn child(e: Element, name: str): Element? {
  for n in e.children {
    match n {
      Elem(c) when c.name == name => return some(c)
      _ => {}
    }
  }
  none
}

/// Every child element named `name`, in order.
pub fn all(e: Element, name: str): [Element] {
  var out: [Element] = []
  for n in e.children {
    match n {
      Elem(c) when c.name == name => out.push(c)
      _ => {}
    }
  }
  out
}

/// Every element named `name` below `e` (not `e` itself), in document order.
pub fn descendants(e: Element, name: str): [Element] {
  var out: [Element] = []
  collect(e, name, &out)
  out
}

fn collect(e: Element, name: str, out: var [Element]) {
  for n in e.children {
    match n {
      Elem(c) => {
        if c.name == name { out.push(c) }
        collect(c, name, &out)
      }
      Text(_) => {}
    }
  }
}

/// All the text inside `e`, nested elements included, in document order.
pub fn text(e: Element): str {
  var out = ""
  add_text(e, &out)
  out
}

fn add_text(e: Element, out: var str) {
  for n in e.children {
    match n {
      Elem(c) => add_text(c, &out)
      Text(s) => out += s
    }
  }
}

// ---- parser: a cursor over the chars; loops for anything long, recursion only per nesting level ----

struct P { cs: [char], i: int }

/// Parse an XML document into its root element. An XML declaration, comments, processing
/// instructions and a DOCTYPE (its internal subset is skipped) may surround the root. The
/// predefined entities (`&lt; &gt; &amp; &quot; &apos;`) and character references (`&#169;`,
/// `&#xA9;`) are decoded; other entities are a `BadEntity` error. Line endings become `\n`. An
/// element whose text content is only whitespace (indentation between child elements) has those
/// whitespace `Text` nodes dropped; in mixed content every text node is kept as written.
pub fn parse(s: str): Element!XmlErr {
  let lf = if s.contains('\r') { s.replace("\r\n", "\n").replace("\r", "\n") } else { s }
  var p = P { cs: lf.chars(), i: 0 }
  if p.at('\u{FEFF}') { p.i += 1 }
  misc(&p, true)?
  if !p.at('<') { fail(p.expected("the root element")) }
  let root = element(&p, 0)?
  misc(&p, false)?
  if p.i < p.cs.len() { fail(p.syntax("content after the root element")) }
  root
}

fn peek(p: P): char? = p.cs.get(p.i)
fn at(p: P, c: char): bool = p.i < p.cs.len() && p.cs[p.i] == c

// Is the char after the current one `c`?
fn next_is(p: P, c: char): bool = p.i + 1 < p.cs.len() && p.cs[p.i + 1] == c

let COMMENT = "<!--".chars()
let COMMENT_END = "-->".chars()
let PI_END = "?>".chars()
let CDATA = "<![CDATA[".chars()
let CDATA_END = "]]>".chars()
let DOCTYPE = "<!DOCTYPE".chars()

fn looking(p: P, w: [char]): bool {
  let n = w.len()
  if p.i + n > p.cs.len() { return false }
  var k = 0
  while k < n && p.cs[p.i + k] == w[k] { k += 1 }
  k == n
}

fn skip_ws(p: var P) {
  let n = p.cs.len()
  var i = p.i
  while i < n && (p.cs[i] == ' ' || p.cs[i] == '\n' || p.cs[i] == '\t') { i += 1 }
  p.i = i
}

// 1-based position of index i; only computed on the error path.
fn line(cs: [char], i: int): int {
  var n = 1
  for j in 0..min(i, cs.len()) {
    if cs[j] == '\n' { n += 1 }
  }
  n
}

fn col(cs: [char], i: int): int {
  let end = min(i, cs.len())
  var j = end
  while j > 0 && cs[j - 1] != '\n' { j -= 1 }
  end - j + 1
}

fn syntax(p: P, why: str): XmlErr = Syntax(why, line(p.cs, p.i), col(p.cs, p.i))

fn expected(p: P, want: str): XmlErr {
  let (l, k) = (line(p.cs, p.i), col(p.cs, p.i))
  match p.peek() {
    some(c) => Syntax("expected {want}, found '{c}'", l, k)
    none => Eof(want, l, k)
  }
}

// Advance past the next `end`, or fail at the end of input.
fn skip_past(p: var P, end: [char], want: str): ()!XmlErr {
  let n = p.cs.len()
  let first = end[0]
  while p.i < n {
    if p.cs[p.i] == first && p.looking(end) {
      p.i += end.len()
      return ()
    }
    p.i += 1
  }
  fail(p.expected(want))
}

// Whitespace, comments and processing instructions around the root (and a DOCTYPE before it).
fn misc(p: var P, prolog: bool): ()!XmlErr {
  loop {
    p.skip_ws()
    if p.looking(COMMENT) {
      p.i += 4
      p.skip_past(COMMENT_END, "'-->'")?
    } else if p.at('<') && p.next_is('?') {
      p.i += 2
      p.skip_past(PI_END, "'?>'")?
    } else if prolog && p.looking(DOCTYPE) {
      doctype(&p)?
    } else {
      break
    }
  }
}

fn doctype(p: var P): ()!XmlErr {
  p.i += 9
  var depth = 0
  var quote = '\0'
  while p.i < p.cs.len() {
    let c = p.cs[p.i]
    if quote == '\0' && c == '<' && p.looking(COMMENT) {
      p.i += 4
      p.skip_past(COMMENT_END, "'-->'")?
      continue
    }
    p.i += 1
    if quote != '\0' {
      if c == quote { quote = '\0' }
    } else if c == '"' || c == '\'' {
      quote = c
    } else if c == '[' {
      depth += 1
    } else if c == ']' {
      depth -= 1
    } else if c == '>' && depth <= 0 {
      return ()
    }
  }
  fail(p.expected("'>' ending the DOCTYPE"))
}

fn name_start(c: char): bool = c.is_alpha() || c == '_' || c == ':' || int(c) > 127
fn name_char(c: char): bool = name_start(c) || c.is_digit() || c == '-' || c == '.'

fn name(p: var P, what: str): str!XmlErr {
  let from = p.i
  let n = p.cs.len()
  if !(from < n && name_start(p.cs[from])) { fail(p.expected(what)) }
  var i = from + 1
  while i < n && name_char(p.cs[i]) { i += 1 }
  p.i = i
  core.str(p.cs[from..i])
}

// p is at '<'; depth = how many elements enclose this one
fn element(p: var P, depth: int): Element!XmlErr {
  if depth >= MAX_DEPTH { fail(TooDeep(line(p.cs, p.i), col(p.cs, p.i))) }
  p.i += 1  // <
  let name = p.name("an element name")?
  var attrs: {str: str} = {}
  loop {
    let before = p.i
    p.skip_ws()
    if p.at('/') && p.next_is('>') {
      p.i += 2
      return Element { name, attrs, children: [] }
    }
    if p.at('>') {
      p.i += 1
      break
    }
    if p.i == before { fail(p.expected("whitespace, '>' or '/>'")) }
    let key_at = p.i
    let key = p.name("an attribute name, '>' or '/>'")?
    if attrs.get(key) is some(_) {
      fail(DuplicateAttr(key, line(p.cs, key_at), col(p.cs, key_at)))
    }
    p.skip_ws()
    if !p.at('=') { fail(p.expected("'=' after attribute '{key}'")) }
    p.i += 1
    p.skip_ws()
    let q = match p.peek() {
      some(c) when c == '"' || c == '\'' => c
      _ => fail(p.expected("a quoted value for attribute '{key}'"))
    }
    p.i += 1
    attrs[key] = text_until(&p, q, true)?
  }
  var kids: [Node] = []
  var pending = ""   // text since the last child element, merged into one Text node
  var texts = false  // is any of the kids a Text?
  let n = p.cs.len()
  loop {
    if p.i >= n { fail(p.expected("</{name}>")) }
    if p.cs[p.i] != '<' {
      pending += text_until(&p, '<', false)?
      continue
    }
    let c = if p.i + 1 < n { p.cs[p.i + 1] } else { '<' }
    if c == '/' {
      let close_at = p.i
      p.i += 2
      let close = p.name("the closing tag's name")?
      p.skip_ws()
      if !p.at('>') { fail(p.expected("'>'")) }
      if close != name {
        fail(Mismatch(name, close, line(p.cs, close_at), col(p.cs, close_at)))
      }
      p.i += 1
      break
    } else if c == '!' && p.looking(COMMENT) {
      p.i += 4
      p.skip_past(COMMENT_END, "'-->'")?
    } else if c == '!' && p.looking(CDATA) {
      p.i += 9
      let from = p.i
      p.skip_past(CDATA_END, "']]>'")?
      pending += core.str(p.cs[from..p.i - 3])
    } else if c == '?' {
      p.i += 2
      p.skip_past(PI_END, "'?>'")?
    } else {
      if pending != "" {
        kids.push(Text(pending))
        pending = ""
        texts = true
      }
      kids.push(Elem(element(&p, depth + 1)?))
    }
  }
  if pending != "" {
    kids.push(Text(pending))
    texts = true
  }
  if !texts { return Element { name, attrs, children: kids } }
  let mixed = kids.any(n => match n {
    Text(s) => s.trim() != ""
    Elem(_) => false
  })
  let children = if mixed { kids } else { kids.filter(n => n is Elem(_)) }
  Element { name, attrs, children }
}

// Text up to `stop` with entities decoded. In an attribute value (`attr`), `stop` is the closing
// quote (consumed), `<` is an error, and tabs and newlines become spaces (XML's normalization).
fn text_until(p: var P, stop: char, attr: bool): str!XmlErr {
  let n = p.cs.len()
  var out = ""
  var from = p.i
  var i = from
  loop {
    if i >= n {
      p.i = i
      if attr { fail(p.expected("the closing {stop}")) }
      break
    }
    let c = p.cs[i]
    if c == stop { break }
    if c == '&' {
      out += core.str(p.cs[from..i])
      p.i = i
      out += entity(&p)?
      i = p.i
      from = i
    } else if attr && c == '<' {
      p.i = i
      fail(p.syntax("'<' in an attribute value (write &lt;)"))
    } else if attr && (c == '\n' || c == '\t') {
      out += core.str(p.cs[from..i])
      out += " "
      i += 1
      from = i
    } else {
      i += 1
    }
  }
  p.i = if attr { i + 1 } else { i }
  let tail = core.str(p.cs[from..i])
  if out == "" { tail } else { out + tail }
}

// p is at '&'
fn entity(p: var P): str!XmlErr {
  let start = p.i
  let n = p.cs.len()
  var j = start + 1
  while j < n && j - start < 12 && !entity_end(p.cs[j]) { j += 1 }
  let found = j < n && p.cs[j] == ';'
  if !found { fail(BadEntity(core.str(p.cs[start..j]), line(p.cs, start), col(p.cs, start))) }
  let out = decode_entity(core.str(p.cs[start + 1..j])) else {
    fail(BadEntity(core.str(p.cs[start..j + 1]), line(p.cs, start), col(p.cs, start)))
  }
  p.i = j + 1
  out
}

fn entity_end(c: char): bool =
  c == ';' || c == '&' || c == '<' || c == ' ' || c == '\n' || c == '\t'

fn decode_entity("lt"): str? = "<"
fn decode_entity("gt"): str? = ">"
fn decode_entity("amp"): str? = "&"
fn decode_entity("quot"): str? = "\""
fn decode_entity("apos"): str? = "'"
fn decode_entity("#x" + hex): str? = code_point(number(hex, 16)?)
fn decode_entity("#" + dec): str? = code_point(number(dec, 10)?)
fn decode_entity(_: str): str? = none

fn number(s: str, base: int): int? {
  if s == "" || s.len() > 8 { return none }
  var n = 0
  for c in s.lower().chars() {
    let d = "0123456789abcdef".find(core.str(c))?
    if d >= base { return none }
    n = n * base + d
  }
  n
}

// The chars XML allows: tab, newline, CR, U+0020..U+D7FF, U+E000..U+FFFD, U+10000..U+10FFFF.
fn code_point(n: int): str? {
  if n < 32 && n != 9 && n != 10 && n != 13 { return none }
  if n == 0xFFFE || n == 0xFFFF { return none }
  core.str(char(n)?)
}

// ---- writers ----

/// Escape text for element content: `& < >` (and CR, which parsing would turn into `\n`).
pub fn escape(s: str): str {
  if !(s.contains("&") || s.contains("<") || s.contains(">") || s.contains("\r")) { return s }
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\r", "&#13;")
}

fn escape_attr(s: str): str {
  let e = escape(s)
  if !(e.contains("\"") || e.contains("\n") || e.contains("\t")) { return e }
  e.replace("\"", "&quot;").replace("\n", "&#10;").replace("\t", "&#9;")
}

fn open_tag(e: Element, out: var str) {
  out += "<"
  out += e.name
  for k, v in e.attrs {
    out += " "
    out += k
    out += "=\""
    out += escape_attr(v)
    out += "\""
  }
}

/// Compact XML for `e` (no declaration, no added whitespace); an element with no children is
/// written `<x/>`. `parse(str(e)) == e` for any tree `parse` can produce.
pub fn str(e: Element): str {
  var out = ""
  write(e, &out)
  out
}

fn write(e: Element, out: var str) {
  open_tag(e, &out)
  if e.children.len() == 0 {
    out += "/>"
    return ()
  }
  out += ">"
  for n in e.children {
    match n {
      Elem(c) => write(c, &out)
      Text(s) => out += escape(s)
    }
  }
  out += "</"
  out += e.name
  out += ">"
}

/// Indented XML (2 spaces per level, no declaration). Elements with text content are written on
/// one line, exactly as `str` would, so mixed content keeps its whitespace.
pub fn pretty(e: Element): str {
  var out = ""
  write_pretty(e, 0, &out)
  out
}

// Each element starts a new line (the first line has no break before it).
fn write_pretty(e: Element, level: int, out: var str) {
  if out != "" { out += "\n" }
  let pad = "  ".repeat(level)
  out += pad
  if e.children.len() == 0 || e.children.any(n => n is Text(_)) {
    write(e, &out)
    return ()
  }
  open_tag(e, &out)
  out += ">"
  for n in e.children {
    match n {
      Elem(c) => write_pretty(c, level + 1, &out)
      Text(_) => {}
    }
  }
  out += "\n"
  out += pad
  out += "</"
  out += e.name
  out += ">"
}

/// An element with no attributes holding just `text` (or nothing, if `text` is empty).
pub fn leaf(name: str, text: str): Element {
  let children: [Node] = if text == "" { [] } else { [Text(text)] }
  Element { name, attrs: {}, children }
}

// ---- tests ----

test "elements, attributes and text" {
  let e = parse(r"""<?xml version="1.0" encoding="UTF-8"?>
<!-- a catalog -->
<catalog lang="en">
  <book id="1" year='1999'><title>Auk &amp; Cover</title></book>
  <book id="2"><title>Raft</title><tag/></book>
</catalog>
""")?
  assert e.name == "catalog"
  assert e.attr("lang") == some("en")
  assert e.attr("nope") == none
  assert e.children.len() == 2  // indentation-only text is dropped
  let books = e.all("book")
  assert books.map(b => b.attr("id") else "") == ["1", "2"]
  assert books[0].attr("year") == some("1999")
  assert books[0].child("title")?.text() == some("Auk & Cover")
  assert e.descendants("title").map(t => t.text()) == ["Auk & Cover", "Raft"]
  assert books[1].child("tag") == some(Element { name: "tag", attrs: {}, children: [] })
}

test "descendants finds nested matches in document order" {
  let e = parse("<r><d n='1'><d n='2'/></d><x><d n='3'/></x></r>")?
  assert e.descendants("d").map(d => d.attr("n") else "") == ["1", "2", "3"]
}

test "entities and character references" {
  let e = parse("<a t=\"&quot;x&quot; &lt;3\">&#65;&#x42;&apos;&gt;&#x1F986;</a>")?
  assert e.attr("t") == some("\"x\" <3")
  assert e.text() == "AB'>\u{1F986}"
}

test "CDATA is text and comments vanish" {
  let e = parse("<s>if <![CDATA[a < b && c]]> then<!-- no --> ok</s>")?
  assert e.children == [Text("if a < b && c then ok")]
}

test "mixed content keeps its whitespace" {
  let e = parse("<p>Hello <b>big</b> <i>world</i>!</p>")?
  assert e.text() == "Hello big world!"
  assert e.children.len() == 5
  assert str(e) == "<p>Hello <b>big</b> <i>world</i>!</p>"
}

test "attribute values normalize tabs and newlines" {
  let e = parse("<a v=\"x\ny\tz\"/>")?
  assert e.attr("v") == some("x y z")
}

test "DOCTYPE with an internal subset, BOM, CRLF and namespaces" {
  let e = parse("\u{FEFF}<!DOCTYPE note [<!ELEMENT note (#PCDATA)> <!-- ] -->]>\r\n<soap:Body xmlns:soap=\"u\">a\r\nb</soap:Body>")?
  assert e.name == "soap:Body"
  assert e.attr("xmlns:soap") == some("u")
  assert e.text() == "a\nb"
}

test "round trip through str and pretty" {
  let src = "<r a=\"1 &amp; &quot;2&quot;\"><x>t &lt; u</x><y><z/></y><m>a <b>c</b></m></r>"
  let e = parse(src)?
  assert str(e) == src
  assert parse(pretty(e))? == e
  assert pretty(e) + "\n" == """
    <r a="1 &amp; &quot;2&quot;">
      <x>t &lt; u</x>
      <y>
        <z/>
      </y>
      <m>a <b>c</b></m>
    </r>
    """
}

test "building a tree by hand" {
  let e = Element {
    name: "order",
    attrs: {"id": "7"},
    children: [Elem(leaf("item", "tea & cake")), Elem(leaf("note", ""))],
  }
  assert str(e) == "<order id=\"7\"><item>tea &amp; cake</item><note/></order>"
  assert parse(str(e))? == e
}

fn err_of(s: str): str = match parse(s) {
  ok(_) => "ok"
  err(e) => message(e)
}

test "errors carry positions" {
  assert err_of("<a>\n  <b></a>") == "2:6: </a> closes <b>"
  assert err_of("<a>") == "1:4: unexpected end of input (expected </a>)"
  assert err_of("<a x=1/>") == "1:6: expected a quoted value for attribute 'x', found '1'"
  assert err_of("<a x='1' x='2'/>") == "1:10: attribute 'x' is repeated"
  assert err_of("<a>&nbsp;</a>") == "1:4: unknown or malformed entity '&nbsp;'"
  assert err_of("<a>AT&T</a>") == "1:6: unknown or malformed entity '&T'"
  assert err_of("<a>&#0;</a>") == "1:4: unknown or malformed entity '&#0;'"
  assert err_of("<a/><b/>") == "1:5: content after the root element"
  assert err_of("hello") == "1:1: expected the root element, found 'h'"
  assert err_of("") == "1:1: unexpected end of input (expected the root element)"
  assert err_of("<a b='<'/>") == "1:7: '<' in an attribute value (write &lt;)"
  assert err_of("<a x='1'y='2'/>") == "1:9: expected whitespace, '>' or '/>', found 'y'"
}

test "deep nesting is an error, not a crash" {
  let deep = "<a>".repeat(MAX_DEPTH + 1) + "</a>".repeat(MAX_DEPTH + 1)
  assert parse(deep) is err(TooDeep(_, _))
  let ok_depth = "<a>".repeat(MAX_DEPTH) + "</a>".repeat(MAX_DEPTH)
  assert parse(ok_depth) is ok(_)
}
