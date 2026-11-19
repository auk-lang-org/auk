/// Markdown to HTML: CommonMark blocks and inlines (headings, paragraphs, emphasis, code,
/// block quotes, nested lists, links and images, reference definitions, hard breaks, rules) and
/// the GitHub extensions (tables, ~~strikethrough~~, task lists, bare URL autolinks). `parse`
/// gives a tree, `to_html` renders it, `html` does both. Raw HTML in the input is escaped
/// unless `Opts.unsafe_html` is set, and `javascript:`-style URLs are dropped, so `html(s)` is
/// safe for untrusted text. Pure: no effects.

pub enum Align { NoAlign, Left, Center, Right }

pub enum Inline {
  Text(s: str),
  Code(s: str),
  Em(body: [Inline]),
  Strong(body: [Inline]),
  Del(body: [Inline]),
  Link(url: str, title: str, body: [Inline]),
  Image(url: str, title: str, alt: [Inline]),
  SoftBreak,
  HardBreak,
  Html(s: str),
}

/// A list item: `checked` is some(...) for a GitHub task item (`- [ ]` / `- [x]`).
pub struct Item { checked: bool?, blocks: [Block] }

pub enum Block {
  Heading(level: int, body: [Inline]),
  Para(body: [Inline]),
  CodeBlock(lang: str, code: str),
  Quote(blocks: [Block]),
  List(ordered: bool, start: int, tight: bool, items: [Item]),
  Rule,
  Table(align: [Align], head: [[Inline]], rows: [[[Inline]]]),
  HtmlBlock(html: str),
}

/// Rendering options. `unsafe_html` passes raw HTML and every URL through untouched; only for
/// trusted input.
pub struct Opts { unsafe_html: bool }

pub let SAFE = Opts { unsafe_html: false }

/// Markdown to HTML, safe for untrusted input.
pub fn html(src: str): str = to_html(parse(src), SAFE)
/// Markdown to HTML with options.
pub fn html(src: str, opts: Opts): str = to_html(parse(src), opts)

/// The text of a document without markup (block per paragraph, blank lines between), for
/// previews, search indexes and `<title>`s.
pub fn text(src: str): str = plain(parse(src))

// ---- block structure ----

struct Ref { url: str, title: str }

/// Parses a document into blocks.
pub fn parse(src: str): [Block] {
  let unix = if src.contains("\r") { src.replace("\r\n", "\n").replace("\r", "\n") } else { src }
  let lines = unix.split("\n").map(expand_tabs)
  var refs: {str: Ref} = {}
  let raw = blocks(lines, &refs)
  raw.map(b => resolve(b, refs))
}

// Leading tabs become spaces to the next multiple of 4.
fn expand_tabs(l: str): str {
  if !l.contains("\t") { return l }
  var out: [char] = []
  var lead = true
  for c in l.chars() {
    if lead && c == '\t' {
      out.push(' ')
      while out.len() % 4 != 0 { out.push(' ') }
    } else {
      if c != ' ' { lead = false }
      out.push(c)
    }
  }
  str(out)
}

fn blank(l: str): bool {
  let n = l.len()
  var i = 0
  while i < n && l[i].is_space() { i += 1 }
  i == n
}

fn indent(l: str): int {
  var i = 0
  while i < l.len() && l[i] == ' ' { i += 1 }
  i
}

fn strip_indent(l: str, n: int): str {
  var i = 0
  while i < n && i < l.len() && l[i] == ' ' { i += 1 }
  if i == 0 { l } else { l[i..l.len()] }
}

fn rtrim(s: str): str = s.trim_end()

struct Fence { ch: char, len: int, ind: int, info: str }

fn fence_start(l: str): Fence? {
  let ind = indent(l)
  if ind > 3 || ind >= l.len() { return none }
  let ch = l[ind]
  if ch != '`' && ch != '~' { return none }
  let s = l[ind..l.len()]
  var k = 0
  while k < s.len() && s[k] == ch { k += 1 }
  if k < 3 { return none }
  let info = s[k..s.len()].trim()
  if ch == '`' && info.contains("`") { return none }
  some(Fence { ch, len: k, ind, info })
}

fn closes_fence(l: str, f: Fence): bool {
  let ind = indent(l)
  if ind > 3 { return false }
  let s = l[ind..l.len()].trim()
  s.len() >= f.len && s.chars().all(c => c == f.ch)
}

fn atx(l: str): (int, str)? {
  let ind = indent(l)
  if ind > 3 || ind >= l.len() || l[ind] != '#' { return none }
  let s = l[ind..l.len()]
  var k = 0
  while k < s.len() && s[k] == '#' { k += 1 }
  if k == 0 || k > 6 { return none }
  if k < s.len() && s[k] != ' ' && s[k] != '\t' { return none }
  var body = s[k..s.len()].trim()
  // a closing run of #s, preceded by a space or making up the whole body
  var e = body.len()
  while e > 0 && body[e - 1] == '#' { e -= 1 }
  if e == 0 {
    body = ""
  } else if e < body.len() && body[e - 1] == ' ' {
    body = body[0..e].trim()
  }
  some((k, body))
}

fn is_rule(l: str): bool {
  let ind = indent(l)
  if ind > 3 || ind >= l.len() { return false }
  let c0 = l[ind]
  if c0 != '*' && c0 != '-' && c0 != '_' && !c0.is_space() { return false }
  let s = l.trim()
  if s == "" { return false }
  let c = s[0]
  if c != '*' && c != '-' && c != '_' { return false }
  var n = 0
  for d in s.chars() {
    if d == c {
      n += 1
    } else if d != ' ' && d != '\t' {
      return false
    }
  }
  n >= 3
}

fn setext(l: str): int? {
  let ind = indent(l)
  if ind > 3 || ind >= l.len() { return none }
  let c0 = l[ind]
  if c0 != '=' && c0 != '-' && !c0.is_space() { return none }
  let s = l.trim()
  if s == "" { return none }
  let c = s[0]
  if c != '=' && c != '-' { return none }
  if s.chars().all(d => d == c) { some(if c == '=' { 1 } else { 2 }) } else { none }
}

fn quote_start(l: str): bool {
  let ind = indent(l)
  if ind > 3 || ind >= l.len() { return false }
  let c0 = l[ind]
  c0 == '>' || (c0.is_space() && l.trim().starts_with(">"))
}

fn strip_quote(l: str): str {
  let s = l[indent(l) + 1..l.len()]
  if s.starts_with(" ") { s[1..s.len()] } else { s }
}

struct Marker { ordered: bool, ch: char, start: int, offset: int, rest: str }

fn list_marker(l: str): Marker? {
  let ind = indent(l)
  if ind > 3 || ind >= l.len() { return none }
  let c0 = l[ind]
  if c0 != '-' && c0 != '+' && c0 != '*' && !c0.is_digit() { return none }
  let s = l[ind..l.len()]
  var ordered = false
  var ch = s[0]
  var start = 1
  var w = 0
  if ch == '-' || ch == '+' || ch == '*' {
    w = 1
  } else {
    while w < s.len() && w < 9 && s[w].is_digit() { w += 1 }
    if w == 0 || w >= s.len() || (s[w] != '.' && s[w] != ')') { return none }
    start = int.parse(s[0..w])!
    ch = s[w]
    ordered = true
    w += 1
  }
  let after = s[w..s.len()]
  if after != "" && after[0] != ' ' { return none }
  if blank(after) { return some(Marker { ordered, ch, start, offset: ind + w + 1, rest: "" }) }
  let sp = indent(after)
  if sp >= 5 {
    // the content is indented code: one space belongs to the marker
    return some(Marker { ordered, ch, start, offset: ind + w + 1, rest: after[1..after.len()] })
  }
  some(Marker { ordered, ch, start, offset: ind + w + sp, rest: after[sp..after.len()] })
}

let BLOCK_TAGS = """
  address article aside base basefont blockquote body caption center col colgroup dd details
  dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6
  head header hr html iframe legend li link main menu menuitem nav noframes ol optgroup option p
  param search section summary table tbody td tfoot th thead title tr track ul
  """.split()

// Which of CommonMark's seven kinds of HTML block line `l` starts (0: none).
fn html_kind(l: str): int {
  let ind = indent(l)
  if ind > 3 || ind >= l.len() || l[ind] != '<' { return 0 }
  let s = l[ind..l.len()]
  let low = s.lower()
  for t in ["script", "pre", "style", "textarea"] {
    if low.starts_with("<" + t) {
      let rest = s[t.len() + 1..s.len()]
      if rest == "" || rest[0] == ' ' || rest[0] == '\t' || rest[0] == '>' { return 1 }
    }
  }
  if s.starts_with("<!--") { return 2 }
  if s.starts_with("<?") { return 3 }
  if s.starts_with("<![CDATA[") { return 5 }
  if s.starts_with("<!") && s.len() > 2 && s[2].is_alpha() { return 4 }
  var k = 1
  if k < s.len() && s[k] == '/' { k += 1 }
  let st = k
  while k < s.len() && (s[k].is_alpha() || s[k].is_digit()) { k += 1 }
  let name = low[st..k]
  if name != "" && BLOCK_TAGS.contains(name) {
    let rest = s[k..s.len()]
    if rest == "" ||
      rest[0] == ' ' ||
      rest[0] == '\t' ||
      rest.starts_with(">") ||
      rest.starts_with("/>") {
      return 6
    }
  }
  match tag_end(s.chars(), 0) {
    some(e) => if blank(s[e..s.len()]) { 7 } else { 0 }
    none => 0
  }
}

fn html_ends(kind: int, l: str): bool = match kind {
  1 => {
    let low = l.lower()
    low.contains("</script>") ||
      low.contains("</pre>") ||
      low.contains("</style>") ||
      low.contains("</textarea>")
  }
  2 => l.contains("-->")
  3 => l.contains("?>")
  4 => l.contains(">")
  5 => l.contains("]]>")
  _ => false
}

fn html_start(l: str): bool = html_kind(l) != 0

// Lines that end a paragraph without a blank line between.
fn interrupts(l: str): bool {
  // every case below needs one of these first, after at most three spaces
  let ind = indent(l)
  if ind > 3 || ind >= l.len() { return false }
  let c = l[ind]
  if !(c == '`' ||
    c == '~' ||
    c == '#' ||
    c == '*' ||
    c == '-' ||
    c == '_' ||
    c == '+' ||
    c == '>' ||
    c == '<' ||
    c.is_digit() ||
    c.is_space()) {
    return false
  }
  let hk = html_kind(l)
  if fence_start(l) != none ||
    atx(l) != none ||
    is_rule(l) ||
    quote_start(l) ||
    (hk != 0 && hk != 7) {
    return true
  }
  match list_marker(l) {
    some(m) => m.rest != "" && (!m.ordered || m.start == 1)
    none => false
  }
}

// Table cells: split on unescaped `|`, ignoring one leading and trailing pipe.
fn cells(l: str): [str] {
  let cs = l.trim().chars()
  var hi = cs.len()
  var i = if hi > 0 && cs[0] == '|' { 1 } else { 0 }
  if hi > i && cs[hi - 1] == '|' && !(hi - i >= 2 && cs[hi - 2] == '\\') { hi -= 1 }
  var out: [str] = []
  var cur = ""  // the cell so far, up to the run starting at `a`
  var a = i
  while i < hi {
    let c = cs[i]
    if c == '\\' && i + 1 < hi && cs[i + 1] == '|' {
      if i > a { cur += str(cs[a..i]) }
      a = i + 1  // the `|` is kept, the backslash isn't
      i += 2
      continue
    }
    if c == '|' {
      if i > a { cur += str(cs[a..i]) }
      out.push(cur.trim())
      cur = ""
      a = i + 1
    }
    i += 1
  }
  if hi > a { cur += str(cs[a..hi]) }
  out.push(cur.trim())
  out
}

fn table_delim(l: str): [Align]? {
  if indent(l) > 3 || !l.contains("-") { return none }
  var aligns: [Align] = []
  for c in cells(l) {
    if c == "" { return none }
    let left = c.starts_with(":")
    let right = c.ends_with(":")
    let mid = c[if left { 1 } else { 0 }..c.len() - if right && c.len() > 1 { 1 } else { 0 }]
    if mid == "" || !mid.chars().all(d => d == '-') { return none }
    aligns.push(
      if left && right { Center } else if left { Left } else if right { Right } else { NoAlign },
    )
  }
  some(aligns)
}

fn pending(raw: str): [Inline] = [Text(raw)]

// Parses lines into blocks. `gaps[k]` tells whether a blank line came before block `k` (after
// an earlier block), which decides whether a list item is loose.
fn blocks(lines: [str], refs: var {str: Ref}, gaps: var [bool]): [Block] {
  var out: [Block] = []
  var i = 0
  let n = lines.len()
  var gap = false
  while i < n {
    if gaps.len() > out.len() { gaps.pop() }  // the last lines made no block (reference definitions)
    let l = lines[i]
    if blank(l) {
      if out.len() > 0 { gap = true }
      i += 1
      continue
    }
    gaps.push(gap)
    gap = false
    if indent(l) >= 4 {
      var code: [str] = []
      while i < n && (blank(lines[i]) || indent(lines[i]) >= 4) {
        code.push(strip_indent(lines[i], 4))
        i += 1
      }
      while code.len() > 0 && blank(code[code.len() - 1]) {
        code.pop()
        i -= 1
      }
      var text = ""
      for c in code {
        text += c
        text += "\n"
      }
      out.push(CodeBlock("", text))
      continue
    }
    match fence_start(l) {
      some(f) => {
        i += 1
        var code: [str] = []
        while i < n {
          if closes_fence(lines[i], f) {
            i += 1
            break
          }
          code.push(strip_indent(lines[i], f.ind))
          i += 1
        }
        let lang = decode_entities(unescape(f.info.split().first() else ""))
        var text = ""
        for c in code {
          text += c
          text += "\n"
        }
        out.push(CodeBlock(lang, text))
        continue
      }
      none => {}
    }
    match atx(l) {
      some((level, body)) => {
        out.push(Heading(level, pending(body)))
        i += 1
        continue
      }
      none => {}
    }
    if is_rule(l) {
      out.push(Rule)
      i += 1
      continue
    }
    if quote_start(l) {
      var inner: [str] = []
      while i < n {
        let m = lines[i]
        if quote_start(m) {
          inner.push(strip_quote(m))
        } else if !blank(m) && para_open(inner) && !interrupts(m) {
          inner.push(lazy(m))  // lazy continuation of a paragraph
        } else {
          break
        }
        i += 1
      }
      out.push(Quote(blocks(inner, &refs)))
      continue
    }
    match list_marker(l) {
      some(first) => {
        let (b, next) = list(lines, i, first, &refs)
        out.push(b)
        i = next
        continue
      }
      none => {}
    }
    let hk = html_kind(l)
    if hk != 0 {
      var hs: [str] = []
      if hk <= 5 {
        // up to and including the line with the end marker
        while i < n {
          hs.push(lines[i])
          i += 1
          if html_ends(hk, hs[hs.len() - 1]) { break }
        }
      } else {
        while i < n && !blank(lines[i]) {
          hs.push(lines[i])
          i += 1
        }
      }
      out.push(HtmlBlock(hs.join("\n") + "\n"))
      continue
    }
    if i + 1 < n && l.contains("|") {
      match table_delim(lines[i + 1]) {
        some(aligns) when cells(l).len() == aligns.len() => {
          let w = aligns.len()
          let head = cells(l).map(pending)
          i += 2
          var rows: [[[Inline]]] = []
          while i < n && !blank(lines[i]) && !interrupts(lines[i]) {
            let cs = cells(lines[i])
            var row: [[Inline]] = []
            for k in 0..w { row.push(pending(cs.get(k) else "")) }
            rows.push(row)
            i += 1
          }
          out.push(Table(aligns, head, rows))
          continue
        }
        _ => {}
      }
    }
    // a paragraph, maybe a setext heading
    var para: [str] = [l.trim_left()]
    i += 1
    var level = 0
    while i < n {
      let m = lines[i]
      if blank(m) { break }
      match setext(m) {
        some(lv) => {
          level = lv
          i += 1
          break
        }
        none => {}
      }
      if interrupts(m) { break }
      para.push(m.trim_left())
      i += 1
    }
    var text = para.join("\n")
    if level == 0 {
      text = take_refs(text, &refs)
      if text != "" { out.push(Para(pending(rtrim(text)))) }
    } else {
      text = take_refs(text, &refs)
      if text == "" {
        i -= 1  // only definitions: the underline starts a paragraph
      } else {
        out.push(Heading(level, pending(rtrim(text))))
      }
    }
  }
  if gaps.len() > out.len() { gaps.pop() }
  out
}

fn blocks(lines: [str], refs: var {str: Ref}): [Block] {
  var gaps: [bool] = []
  blocks(lines, &refs, &gaps)
}

fn trim_left(s: str): str = strip_indent(s, s.len())

// Whether `lines` end inside a paragraph, so a following line can continue it lazily.
fn para_open(lines: [str]): bool {
  var fence: Fence? = none
  var last = ""
  for l in lines {
    match fence {
      some(f) => if closes_fence(l, f) { fence = none }
      none => fence = fence_start(l)
    }
    last = l
  }
  fence == none &&
    !blank(last) &&
    indent(last) < 4 &&
    atx(last) == none &&
    !is_rule(last) &&
    fence_start(last) == none
}

// A lazy continuation line keeps its indentation (so it can't start a block once the container
// marker is gone), and a `===` underline is escaped (a lazy line can't make a setext heading).
fn lazy(l: str): str = if setext(l) != none { "\\" + l.trim() } else { l }

fn same_list(a: Marker, b: Marker): bool = a.ordered == b.ordered && a.ch == b.ch

// One list starting at line `i`; returns it and the index after it.
fn list(lines: [str], i0: int, first: Marker, refs: var {str: Ref}): (Block, int) {
  let n = lines.len()
  var i = i0
  var items: [Item] = []
  var tight = true
  var m = first
  loop {
    var body: [str] = [m.rest]
    i += 1
    // an item can start with at most one blank line
    let empty = m.rest == "" && i < n && blank(lines[i])
    while i < n && !empty {
      let l = lines[i]
      if blank(l) {
        var j = i
        while j < n && blank(lines[j]) { j += 1 }
        if j < n && indent(lines[j]) >= m.offset {
          for _ in i..j { body.push("") }
          i = j
          continue
        }
        break
      }
      if indent(l) >= m.offset {
        body.push(strip_indent(l, m.offset))
      } else if para_open(body) && !interrupts(l) && list_marker(l) == none {
        body.push(lazy(l))  // lazy continuation
      } else {
        break
      }
      i += 1
    }
    var checked: bool? = none
    let r = body[0]
    if r.starts_with("[ ] ") || r == "[ ]" {
      checked = some(false)
      body[0] = r[3..r.len()].trim_left()
    } else if r.starts_with("[x] ") || r.starts_with("[X] ") || r == "[x]" || r == "[X]" {
      checked = some(true)
      body[0] = r[3..r.len()].trim_left()
    }
    var gaps: [bool] = []
    let bs = blocks(body, &refs, &gaps)
    // a blank line between two of the item's direct children makes the list loose
    if gaps.skip(1).any(g => g) { tight = false }
    items.push(Item { checked, blocks: bs })
    var j = i
    while j < n && blank(lines[j]) { j += 1 }
    if j >= n || is_rule(lines[j]) { break }
    let next = list_marker(lines[j]) else { break }
    if !same_list(first, next) { break }
    if j > i { tight = false }
    i = j
    m = next
  }
  (List(first.ordered, first.start, tight, items), i)
}

// Link reference definitions at the start of a paragraph: `[label]: url "title"`. Records them
// and returns what's left.
fn take_refs(text: str, refs: var {str: Ref}): str {
  if !text.starts_with("[") { return text }
  let cs = text.chars()
  let n = cs.len()
  var at = 0
  loop {
    let (label, url, title, next) = ref_def(cs, at) else { break }
    let key = norm_label(label)
    if refs.get(key) == none { refs[key] = Ref { url, title } }
    at = next
    if at >= n { return "" }
  }
  if at == 0 { text } else { str(cs[at..n]) }
}

fn norm_label(s: str): str = s.split().join(" ").lower()

fn skip_ws(s: [char], i0: int, newline: bool): int {
  let n = s.len()
  var i = i0
  var nl = 0
  while i < n && (s[i] == ' ' || (s[i] == '\n' && newline)) {
    if s[i] == '\n' {
      nl += 1
      if nl > 1 { return i }
    }
    i += 1
  }
  i
}

// A definition starting at `st`: its label, url and title, and the index after its line.
fn ref_def(s: [char], st: int): (str, str, str, int)? {
  let n = s.len()
  if st >= n || s[st] != '[' { return none }
  var i = st + 1
  while i < n && s[i] != ']' {
    if s[i] == '[' { return none }
    if s[i] == '\\' && i + 1 < n { i += 1 }
    i += 1
  }
  if i + 1 >= n || s[i + 1] != ':' { return none }
  let label = str(s[st + 1..i])
  if label.trim() == "" { return none }
  i = skip_ws(s, i + 2, true)
  let (url, after) = dest(s, i)?
  if url == "" && (after <= i || s[i] != '<') { return none }
  var j = skip_ws(s, after, true)
  var title = ""
  var end = after
  match title_at(s, j) {
    some((t, k)) => if j > after && line_end(s, k) {
      title = t
      end = k
    }
    none => {}
  }
  if !line_end(s, end) { return none }
  let e = skip_ws(s, end, false)
  some((label, decode_entities(unescape(url)), decode_entities(unescape(title)), min(e + 1, n)))
}

fn line_end(s: [char], i: int): bool {
  let e = skip_ws(s, i, false)
  e >= s.len() || s[e] == '\n'
}

// A link destination at `i`: `<...>` or a run without spaces and with balanced parens. The
// text is returned as written (escapes included).
fn dest(s: [char], i: int): (str, int)? {
  let n = s.len()
  if i < n && s[i] == '<' {
    var j = i + 1
    while j < n && s[j] != '>' {
      if s[j] == '\n' || s[j] == '<' { return none }
      if s[j] == '\\' && j + 1 < n { j += 1 }
      j += 1
    }
    if j >= n { return none }
    return some((str(s[i + 1..j]), j + 1))
  }
  var j = i
  var depth = 0
  while j < n {
    let c = s[j]
    if c == ' ' || c == '\n' || int(c) < 32 { break }
    if c == '\\' && j + 1 < n {
      j += 2
      continue
    }
    if c == '(' { depth += 1 }
    if c == ')' {
      if depth == 0 { break }
      depth -= 1
    }
    j += 1
  }
  if depth != 0 { return none }
  some((if j > i { str(s[i..j]) } else { "" }, j))
}

fn title_at(s: [char], i: int): (str, int)? {
  let n = s.len()
  if i >= n { return none }
  let open = s[i]
  let close = match open {
    '"' => '"'
    '\'' => '\''
    '(' => ')'
    _ => return none
  }
  var j = i + 1
  while j < n && s[j] != close {
    if s[j] == '\\' && j + 1 < n { j += 1 }
    j += 1
  }
  if j >= n { return none }
  some((str(s[i + 1..j]), j + 1))
}

// ASCII punctuation: `!` to `/`, `:` to `@`, `[` to `` ` ``, `{{` to `~`.
fn is_punct(c: char): bool {
  let k = int(c)
  k >= 33 && k <= 47 || (k >= 58 && k <= 64) || (k >= 91 && k <= 96) || (k >= 123 && k <= 126)
}

// Backslash escapes of ASCII punctuation.
fn unescape(s: str): str {
  if !s.contains("\\") { return s }
  let cs = s.chars()
  let n = cs.len()
  var out = ""
  var a = 0  // start of the run not yet copied
  var i = 0
  while i < n {
    if cs[i] == '\\' && i + 1 < n && is_punct(cs[i + 1]) {
      if i > a { out += str(cs[a..i]) }
      a = i + 1
      i += 2
    } else {
      i += 1
    }
  }
  if n > a { out += str(cs[a..n]) }
  out
}

// ---- inlines ----

fn resolve(b: Block, refs: {str: Ref}): Block = match b {
  Heading(lv, [Text(raw)]) => Heading(lv, inlines(raw, refs))
  Para([Text(raw)]) => Para(inlines(raw, refs))
  Quote(bs) => Quote(bs.map(x => resolve(x, refs)))
  List(o, s, t, items) => List(
    o,
    s,
    t,
    items.map(it => Item { checked: it.checked, blocks: it.blocks.map(x => resolve(x, refs)) }),
  )
  Table(a, head, rows) =>
    Table(a, head.map(c => cell(c, refs)), rows.map(r => r.map(c => cell(c, refs))))
  _ => b
}

fn cell(c: [Inline], refs: {str: Ref}): [Inline] = match c {
  [Text(raw)] => inlines(raw, refs)
  _ => c
}

enum Tk { N(x: Inline), D(ch: char, n: int, open: bool, close: bool) }

fn is_ws(c: char): bool = c == ' ' ||
  c == '\n' ||
  c == '\t' ||
  c == '\0' ||
  int(c) == 0xa0 ||
  int(c) == 0x3000 ||
  (int(c) >= 0x2000 && int(c) <= 0x200a) ||
  int(c) == 0x202f ||
  int(c) == 0x205f

// ASCII punctuation, plus common Unicode punctuation and symbols (for emphasis flanking).
fn is_punct_u(c: char): bool = if int(c) < 128 {
  is_punct(c)
} else {
  "¡§«¶·»¿–—‘’‚“”„†‡•…‰′″‹›€£¥¢©®°±×÷".contains(c)
}

/// Parses inline markdown (`*em*`, `` `code` ``, links, ...) with the given reference definitions.
fn inlines(s: str, refs: {str: Ref}): [Inline] = parse_inl(s.chars(), refs, true)

// The pending text: `txt` (already copied) then the literal run `cs[a..b]`.
fn flush(tks: var [Tk], txt: str, cs: [char], a: int, b: int) {
  if b > a {
    tks.push(N(Text(if txt == "" { str(cs[a..b]) } else { txt + str(cs[a..b]) })))
  } else if txt != "" {
    tks.push(N(Text(txt)))
  }
}

// One pass over the chars. Text is not copied char by char: `a` marks where the literal run in
// progress starts, and `txt` holds what came before it in the same text node (only escapes and
// entities end a run without ending the node). `links` is false inside a link's text.
fn parse_inl(cs: [char], refs: {str: Ref}, links: bool): [Inline] {
  let n = cs.len()
  var tks: [Tk] = []
  var txt = ""
  var a = 0
  var i = 0
  while i < n {
    let c = cs[i]
    let u = int(c)
    // nothing below applies to these: letters but `h`/`w`, digits, space, `+ , - . / : ; = > ? @`,
    // `{{ | }}` and everything past ASCII
    if u > 126 ||
      (u >= 97 && u <= 125 && u != 104 && u != 119) ||
      (u >= 43 && u <= 90 && u != 60) ||
      u == 32 {
      i += 1
      continue
    }
    if c == '\\' && i + 1 < n {
      let d = cs[i + 1]
      if d == '\n' {
        flush(&tks, txt, cs, a, i)
        txt = ""
        tks.push(N(HardBreak))
        i = skip_spaces(cs, i + 2)
        a = i
        continue
      }
      if is_punct(d) {
        if i > a { txt += str(cs[a..i]) }
        a = i + 1  // the escaped char starts the next run
        i += 2
        continue
      }
    }
    if c == '`' {
      var k = i
      while k < n && cs[k] == '`' { k += 1 }
      let run = k - i
      match find_run(cs, k, run) {
        some(e) => {
          flush(&tks, txt, cs, a, i)
          txt = ""
          var code = str(cs[k..e]).replace("\n", " ")
          if code.len() >= 2 && code.starts_with(" ") && code.ends_with(" ") && code.trim() != "" {
            code = code[1..code.len() - 1]
          }
          tks.push(N(Code(code)))
          i = e + run
          a = i
        }
        none => i = k  // literal backticks
      }
      continue
    }
    if c == '*' || c == '_' || c == '~' {
      var k = i
      while k < n && cs[k] == c { k += 1 }
      let run = k - i
      if c != '~' || run <= 2 {
        let before = if i == 0 { '\0' } else { cs[i - 1] }
        let after = if k >= n { '\0' } else { cs[k] }
        let left = !is_ws(after) && (!is_punct_u(after) || is_ws(before) || is_punct_u(before))
        let right = !is_ws(before) && (!is_punct_u(before) || is_ws(after) || is_punct_u(after))
        let (open, close) = if c == '_' {
          (left && (!right || is_punct_u(before)), right && (!left || is_punct_u(after)))
        } else {
          (left, right)
        }
        flush(&tks, txt, cs, a, i)
        txt = ""
        tks.push(D(c, run, open, close))
        a = k
      }
      i = k
      continue
    }
    let img = c == '!' && i + 1 < n && cs[i + 1] == '['
    if (c == '[' && links) || img {
      let lb = if img { i + 1 } else { i }
      match link_at(cs, refs, lb) {
        some((j, url, title, end)) => {
          // a link can't contain another link: then only the inner one is a link. (When the
          // text has no link, parsing it again with `links` off would give the same nodes.)
          let body = parse_inl(cs[lb + 1..j], refs, true)
          if img || !has_link(body) {
            flush(&tks, txt, cs, a, i)
            txt = ""
            tks.push(N(if img { Image(url, title, body) } else { Link(url, title, body) }))
            i = end
            a = i
            continue
          }
        }
        none => {}
      }
    }
    if c == '<' {
      match angle(cs, i) {
        some((node, end)) => {
          flush(&tks, txt, cs, a, i)
          txt = ""
          tks.push(N(node))
          i = end
          a = i
          continue
        }
        none => {}
      }
    }
    if c == '&' {
      match entity_len(cs, i) {
        some(m) => match decode_one(str(cs[i..i + m])) {
          some(r) => {
            if i > a { txt += str(cs[a..i]) }
            txt += r
            i += m
            a = i
            continue
          }
          none => {}
        }
        none => {}
      }
    }
    if c == '\n' {
      // spaces before the line break go; two or more make it a hard break
      var e = i
      var sp = 0
      while e > a && cs[e - 1] == ' ' {
        e -= 1
        sp += 1
      }
      if e == a {
        while txt.ends_with(" ") {
          txt = txt[0..txt.len() - 1]
          sp += 1
        }
      }
      flush(&tks, txt, cs, a, e)
      txt = ""
      tks.push(N(if sp >= 2 { HardBreak } else { SoftBreak }))
      i = skip_spaces(cs, i + 1)
      a = i
      continue
    }
    if links && (c == 'h' || c == 'w') && (i == 0 || is_ws(cs[i - 1]) || cs[i - 1] == '(') {
      match bare_url(cs, i) {
        some((url, end)) => {
          flush(&tks, txt, cs, a, i)
          txt = ""
          let href = if url.starts_with("www.") { "http://" + url } else { url }
          tks.push(N(Link(href, "", [Text(url)])))
          i = end
          a = i
          continue
        }
        none => {}
      }
    }
    i += 1
  }
  flush(&tks, txt, cs, a, n)
  merge(finish(emphasis(tks)))
}

fn has_link(xs: [Inline]): bool = xs.any(x => match x {
  Link(_, _, _) => true
  Em(b) => has_link(b)
  Strong(b) => has_link(b)
  Del(b) => has_link(b)
  _ => false
})

fn skip_spaces(cs: [char], i0: int): int {
  var i = i0
  while i < cs.len() && cs[i] == ' ' { i += 1 }
  i
}

// The start of the next run of exactly `n` backticks at or after `i`.
fn find_run(cs: [char], i0: int, n: int): int? {
  let len = cs.len()
  var i = i0
  while i < len {
    if cs[i] == '`' {
      var k = i
      while k < len && cs[k] == '`' { k += 1 }
      if k - i == n { return some(i) }
      i = k
    } else {
      i += 1
    }
  }
  none
}

// The matching `]` for the `[` at `i`, skipping escapes, code spans and nested brackets.
fn close_bracket(cs: [char], i: int): int? {
  let n = cs.len()
  var depth = 0
  var j = i
  while j < n {
    let c = cs[j]
    if c == '\\' {
      j += 2
      continue
    }
    if c == '`' {
      var k = j
      while k < n && cs[k] == '`' { k += 1 }
      match find_run(cs, k, k - j) {
        some(e) => j = e + (k - j)
        none => j = k
      }
      continue
    }
    if c == '<' {
      match angle(cs, j) {
        some((_, e)) => {
          j = e
          continue
        }
        none => {}
      }
    }
    if c == '[' { depth += 1 }
    if c == ']' {
      depth -= 1
      if depth == 0 { return some(j) }
    }
    j += 1
  }
  none
}

// A link at the `[` at `i`: inline `[t](url "title")`, full `[t][ref]`, collapsed `[t][]` or
// shortcut `[t]`. Returns the index of the `]` that ends the text, the url, the title and the
// index after the link.
fn link_at(cs: [char], refs: {str: Ref}, i: int): (int, str, str, int)? {
  let n = cs.len()
  let j = close_bracket(cs, i)?
  if j + 1 < n && cs[j + 1] == '(' {
    let k = skip_ws(cs, j + 2, true)
    match dest(cs, k) {
      some((url, e)) => {
        var k2 = skip_ws(cs, e, true)
        var title = ""
        if k2 > e {
          match title_at(cs, k2) {
            some((t, e2)) => {
              title = t
              k2 = skip_ws(cs, e2, true)
            }
            none => {}
          }
        }
        if k2 < n && cs[k2] == ')' {
          return some((j, decode_entities(unescape(url)), decode_entities(unescape(title)), k2 + 1))
        }
      }
      none => {}
    }
  }
  if refs.len() == 0 { return none }
  var key = str(cs[i + 1..j])
  var end = j + 1
  if j + 1 < n && cs[j + 1] == '[' {
    match close_bracket(cs, j + 1) {
      some(e) => {
        let r = str(cs[j + 2..e])
        if r.trim() != "" { key = r }
        end = e + 1
      }
      none => {}
    }
  }
  let r = refs.get(norm_label(key))?
  some((j, r.url, r.title, end))
}

// Whether `cs` has the chars `lit` at `i`.
fn has_at(cs: [char], i: int, lit: [char]): bool {
  if i + lit.len() > cs.len() { return false }
  for k, c in lit {
    if cs[i + k] != c { return false }
  }
  true
}

let SCHEME_HTTPS = "https://".chars()
let SCHEME_HTTP = "http://".chars()
let WWW = "www.".chars()

// `<scheme:...>` and `<a@b.c>` autolinks, and inline raw HTML: tags, comments, `<?...?>`,
// `<!...>` and CDATA.
fn angle(cs: [char], i: int): (Inline, int)? {
  let n = cs.len()
  var j = i + 1
  var colon = false
  var at = false
  while j < n && cs[j] != '>' && cs[j] != '<' && int(cs[j]) > 32 {
    if cs[j] == ':' {
      colon = true
    } else if cs[j] == '@' {
      at = true
    }
    j += 1
  }
  if j < n && cs[j] == '>' && j > i + 1 && (colon || at) {
    let inner = str(cs[i + 1..j])
    match inner.find(":") {
      some(k) => if k >= 2 &&
        k <= 32 &&
        inner[0].is_alpha() &&
        inner[0..k].chars().all(
          c => c.is_alpha() || c.is_digit() || c == '+' || c == '.' || c == '-',
        ) {
        return some((Link(inner, "", [Text(inner)]), j + 1))
      }
      none => {}
    }
    if at && is_email(inner) { return some((Link("mailto:" + inner, "", [Text(inner)]), j + 1)) }
  }
  if i + 1 < n && (cs[i + 1] == '!' || cs[i + 1] == '?') {
    let rest = str(cs[i..n])
    for (open, close) in [("<!--", "-->"), ("<?", "?>"), ("<![CDATA[", "]]>")] {
      if rest.starts_with(open) {
        // `<!-->` and `<!--->` are whole comments, whatever follows
        if open == "<!--" && (rest.starts_with("<!-->") || rest.starts_with("<!--->")) {
          let short = if rest.starts_with("<!-->") { 5 } else { 6 }
          return some((Html(rest[0..short]), i + short))
        }
        let e = rest[open.len()..rest.len()].find(close)?
        let m = open.len() + e + close.len()
        return some((Html(rest[0..m]), i + m))
      }
    }
    if rest.starts_with("<!") && rest.len() > 2 && rest[2].is_alpha() {
      let e = rest.find(">")?
      return some((Html(rest[0..e + 1]), i + e + 1))
    }
  }
  let e = tag_end(cs, i)?
  some((Html(str(cs[i..e])), e))
}

fn is_tag_char(c: char): bool = c.is_alpha() || c.is_digit() || c == '-'
fn is_attr_start(c: char): bool = c.is_alpha() || c == '_' || c == ':'

fn is_attr_char(c: char): bool =
  c.is_alpha() || c.is_digit() || c == '_' || c == ':' || c == '.' || c == '-'

fn is_space_nl(c: char): bool = c == ' ' || c == '\t' || c == '\n'

// What can't be in an unquoted attribute value (besides whitespace).
fn ends_bare_value(c: char): bool =
  c == '"' || c == '\'' || c == '=' || c == '<' || c == '>' || c == '`'

// The index after an open tag `<name attr="v" ...>` / `<name/>` or a closing tag `</name >`
// starting at `i`, or none.
fn tag_end(s: [char], i: int): int? {
  let n = s.len()
  var k = i + 1
  let closing = k < n && s[k] == '/'
  if closing { k += 1 }
  if k >= n || !s[k].is_alpha() { return none }
  while k < n && is_tag_char(s[k]) { k += 1 }
  if closing {
    while k < n && is_space_nl(s[k]) { k += 1 }
    return if k < n && s[k] == '>' { some(k + 1) } else { none }
  }
  loop {
    let ws = k
    while k < n && is_space_nl(s[k]) { k += 1 }
    if k >= n { return none }
    if s[k] == '>' { return some(k + 1) }
    if s[k] == '/' { return if k + 1 < n && s[k + 1] == '>' { some(k + 2) } else { none } }
    if k == ws || !is_attr_start(s[k]) { return none }
    while k < n && is_attr_char(s[k]) { k += 1 }
    var v = k
    while v < n && is_space_nl(s[v]) { v += 1 }
    if v < n && s[v] == '=' {
      v += 1
      while v < n && is_space_nl(s[v]) { v += 1 }
      if v >= n { return none }
      let q = s[v]
      if q == '"' || q == '\'' {
        v += 1
        while v < n && s[v] != q { v += 1 }
        if v >= n { return none }
        k = v + 1
      } else {
        let st = v
        while v < n && !is_space_nl(s[v]) && !ends_bare_value(s[v]) { v += 1 }
        if v == st { return none }
        k = v
      }
    }
  }
}

fn is_email(s: str): bool = match s.split("@") {
  [a, b] => a != "" &&
    b.contains(".") &&
    !b.starts_with(".") &&
    !b.ends_with(".") &&
    (a + b).chars().all(c => c.is_alpha() || c.is_digit() || ".-_+".contains(str([c])))
  _ => false
}

// GitHub's bare autolinks: `https://...`, `http://...`, `www....`.
fn bare_url(cs: [char], i: int): (str, int)? {
  let n = cs.len()
  // `ht` or `ww` first, so most words are turned away at once
  if i + 1 >= n || (cs[i + 1] != 't' && cs[i + 1] != 'w') { return none }
  if !(has_at(cs, i, SCHEME_HTTPS) || has_at(cs, i, SCHEME_HTTP) || has_at(cs, i, WWW)) {
    return none
  }
  var j = i
  var opens = 0
  var closes = 0
  while j < n && !is_ws(cs[j]) && cs[j] != '<' {
    if cs[j] == '(' {
      opens += 1
    } else if cs[j] == ')' {
      closes += 1
    }
    j += 1
  }
  // trailing punctuation, and a `)` with no `(` to match, aren't part of the URL
  loop {
    if j <= i { break }
    let c = cs[j - 1]
    if "?!.,:*_~'\"".contains(c) {
      j -= 1
    } else if c == ')' && opens < closes {
      closes -= 1
      j -= 1
    } else {
      break
    }
  }
  if j <= i { return none }
  let u = str(cs[i..j])
  if u == "www." || u.ends_with("://") || !u.contains(".") { return none }
  some((u, j))
}

fn delim_text(ch: char, n: int): Inline = Text(str([ch]).repeat(n))

// CommonMark's delimiter-run algorithm for `*`, `_` and `~`.
fn emphasis(input: [Tk]): [Tk] {
  var xs = input
  var c = 0
  while c < xs.len() {
    let D(ch, nc, copen, cclose) = xs[c] else {
      c += 1
      continue
    }
    if !cclose {
      c += 1
      continue
    }
    var o = c - 1
    var found = -1
    while o >= 0 {
      match xs[o] {
        D(ch2, no, oopen, oclose) when ch2 == ch && oopen => {
          let odd = (oclose || copen) && (no + nc) % 3 == 0 && !(no % 3 == 0 && nc % 3 == 0)
          let tilde_ok = ch != '~' || no == nc
          if !odd && tilde_ok {
            found = o
            break
          }
        }
        _ => {}
      }
      o -= 1
    }
    if found < 0 {
      c += 1
      continue
    }
    let D(_, no, oopen, oclose) = xs[found] else { break }
    let used = if ch == '~' { nc } else if no >= 2 && nc >= 2 { 2 } else { 1 }
    let body = merge(finish(xs[found + 1..c]))
    let node = if ch == '~' { Del(body) } else if used == 2 { Strong(body) } else { Em(body) }
    var next: [Tk] = xs[0..found]
    if no > used { next.push(D(ch, no - used, oopen, oclose)) }
    next.push(N(node))
    let at = next.len()
    if nc > used { next.push(D(ch, nc - used, copen, cclose)) }
    xs = next + xs[c + 1..xs.len()]
    c = at
  }
  xs
}

fn finish(xs: [Tk]): [Inline] = xs.map(t => match t {
  N(x) => x
  D(ch, n, _, _) => delim_text(ch, n)
})

fn merge(xs: [Inline]): [Inline] {
  // usually there is nothing to merge
  var k = 1
  while k < xs.len() && !(xs[k] is Text(_) && xs[k - 1] is Text(_)) { k += 1 }
  if k >= xs.len() { return xs }
  var out: [Inline] = []
  for x in xs {
    match (out.last(), x) {
      (some(Text(a)), Text(b)) => out[out.len() - 1] = Text(a + b)
      _ => out.push(x)
    }
  }
  out
}

// ---- HTML ----

/// Renders blocks as HTML (CommonMark's reference output format).
pub fn to_html(bs: [Block], opts: Opts): str {
  var out = ""
  for b in bs { block_html(b, opts, false, &out) }
  out
}

fn block_html(b: Block, o: Opts, tight: bool, out: var str) {
  match b {
    Heading(lv, body) => {
      out += "<h{lv}>"
      inl_html(body, o, &out)
      out += "</h{lv}>\n"
    }
    Para(body) => if tight {
      inl_html(body, o, &out)
    } else {
      out += "<p>"
      inl_html(body, o, &out)
      out += "</p>\n"
    }
    CodeBlock(lang, code) => {
      if lang == "" {
        out += "<pre><code>"
      } else {
        out += "<pre><code class=\"language-"
        out += esc(lang)
        out += "\">"
      }
      out += esc(code)
      out += "</code></pre>\n"
    }
    Quote(bs) => {
      out += "<blockquote>\n"
      for x in bs { block_html(x, o, false, &out) }
      out += "</blockquote>\n"
    }
    List(ordered, start, t, items) => {
      let tag = if ordered { "ol" } else { "ul" }
      out += if ordered && start != 1 { "<ol start=\"{start}\">\n" } else { "<{tag}>\n" }
      for it in items {
        out += "<li>"
        match it.checked {
          some(true) => out += "<input checked=\"\" disabled=\"\" type=\"checkbox\" /> "
          some(false) => out += "<input disabled=\"\" type=\"checkbox\" /> "
          none => {}
        }
        for k, x in it.blocks {
          let inline_para = t && x is Para(_)
          if !inline_para && (k == 0 || !t) && !(k == 0 && it.checked != none && x is Para(_)) {
            if k == 0 { out += "\n" }
          }
          block_html(x, o, t, &out)
          if inline_para && k + 1 < it.blocks.len() { out += "\n" }
        }
        out += "</li>\n"
      }
      out += "</{tag}>\n"
    }
    Rule => out += "<hr />\n"
    Table(aligns, head, rows) => {
      let attr = (k: int) => match (aligns.get(k) else NoAlign) {
        Left => " align=\"left\""
        Center => " align=\"center\""
        Right => " align=\"right\""
        NoAlign => ""
      }
      out += "<table>\n<thead>\n<tr>\n"
      for k, c in head {
        out += "<th"
        out += attr(k)
        out += ">"
        inl_html(c, o, &out)
        out += "</th>\n"
      }
      out += "</tr>\n</thead>\n"
      if rows.len() > 0 {
        out += "<tbody>\n"
        for r in rows {
          out += "<tr>\n"
          for k, c in r {
            out += "<td"
            out += attr(k)
            out += ">"
            inl_html(c, o, &out)
            out += "</td>\n"
          }
          out += "</tr>\n"
        }
        out += "</tbody>\n"
      }
      out += "</table>\n"
    }
    HtmlBlock(h) => if o.unsafe_html {
      out += h
    } else {
      out += "<p>"
      out += esc(rtrim(h))
      out += "</p>\n"
    }
  }
}

fn inl_html(xs: [Inline], o: Opts, out: var str) {
  for x in xs {
    match x {
      Text(s) => out += esc(s)
      Code(s) => {
        out += "<code>"
        out += esc(s)
        out += "</code>"
      }
      Em(b) => {
        out += "<em>"
        inl_html(b, o, &out)
        out += "</em>"
      }
      Strong(b) => {
        out += "<strong>"
        inl_html(b, o, &out)
        out += "</strong>"
      }
      Del(b) => {
        out += "<del>"
        inl_html(b, o, &out)
        out += "</del>"
      }
      Link(u, t, b) => {
        out += "<a href=\""
        out += href(u, o, false)
        if t != "" {
          out += "\" title=\""
          out += esc(t)
        }
        out += "\">"
        inl_html(b, o, &out)
        out += "</a>"
      }
      Image(u, t, alt) => {
        out += "<img src=\""
        out += href(u, o, true)
        out += "\" alt=\""
        out += esc(plain_inl(alt))
        if t != "" {
          out += "\" title=\""
          out += esc(t)
        }
        out += "\" />"
      }
      SoftBreak => out += "\n"
      HardBreak => out += "<br />\n"
      Html(s) => out += if o.unsafe_html { s } else { esc(s) }
    }
  }
}

/// `& < > "` as HTML entities.
pub fn esc(s: str): str {
  var out = s
  if s.contains("&") { out = out.replace("&", "&amp;") }
  if s.contains("<") { out = out.replace("<", "&lt;") }
  if s.contains(">") { out = out.replace(">", "&gt;") }
  if s.contains("\"") { out = out.replace("\"", "&quot;") }
  out
}

fn entity_len(s: [char], i: int): int? {
  let n = s.len()
  var j = i + 1
  if j < n && s[j] == '#' {
    j += 1
    let hex = j < n && (s[j] == 'x' || s[j] == 'X')
    if hex { j += 1 }
    let st = j
    while j < n && (s[j].is_digit() || (hex && is_hex(s[j]))) { j += 1 }
    if j == st || j - st > 7 { return none }
  } else {
    let st = j
    while j < n && (s[j].is_alpha() || s[j].is_digit()) { j += 1 }
    if j == st || j - st > 31 { return none }
  }
  if j < n && s[j] == ';' { some(j + 1 - i) } else { none }
}

fn hex2(n: int): str {
  let d = "0123456789ABCDEF"
  str([d[n / 16], d[n % 16]])
}

fn is_hex(c: char): bool = c.is_digit() || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

// The one-char strings of ASCII, by code.
let ASCII: [str] = ascii_strs()

fn ascii_strs(): [str] {
  var xs: [str] = []
  for b in 0..128 { xs.push(str([char(b) else ' '])) }
  xs
}

// URL bytes that are written as they are: letters, digits and `;/?:@=+$,-_.!~*()#` (`&` and
// `'` are also kept, but as entities).
fn url_plain(b: int): bool = (b >= 97 && b <= 122) ||
  (b >= 44 && b <= 59) ||
  (b >= 63 && b <= 90) ||
  b == 95 ||
  b == 126 ||
  b == 33 ||
  (b >= 35 && b <= 36) ||
  (b >= 40 && b <= 43) ||
  b == 61

// A URL for an href/src attribute: unsafe schemes dropped (unless `unsafe_html`), characters
// outside URL syntax percent-encoded, then HTML-escaped.
fn href(u: str, o: Opts, image: bool): str {
  if !o.unsafe_html && !safe_url(u, image) { return "" }
  let bs = u.bytes()
  let n = bs.len()
  var i = 0
  while i < n && url_plain(bs[i]) { i += 1 }
  if i == n { return u }  // the usual case: nothing to encode
  var out = ""
  i = 0
  while i < n {
    let b = bs[i]
    if url_plain(b) {
      out += ASCII[b]
    } else if b == 37 &&
      i + 2 < n &&
      is_hex(char(bs[i + 1]) else ' ') &&
      is_hex(char(bs[i + 2]) else ' ') {
      out += "%"
    } else if b == 38 {
      out += "&amp;"
    } else if b == 39 {
      out += "&#39;"
    } else {
      out += "%"
      out += hex2(b)
    }
    i += 1
  }
  out
}

fn safe_url(u: str, image: bool): bool {
  if !u.contains(":") { return true }
  let l = u.trim().lower()
  let colon = l.find(":") else { return true }
  let slash = l.find("/") else l.len()
  if slash < colon { return true }
  let scheme = l[0..colon]
  if scheme == "javascript" || scheme == "vbscript" || scheme == "file" { return false }
  if scheme == "data" {
    return image &&
      (l.starts_with("data:image/png") ||
        l.starts_with("data:image/gif") ||
        l.starts_with("data:image/jpeg") ||
        l.starts_with("data:image/webp"))
  }
  true
}

// ---- plain text ----

fn plain(bs: [Block]): str = bs.map(plain_block).filter(s => s != "").join("\n\n")

fn plain_block(b: Block): str = match b {
  Heading(_, body) => plain_inl(body)
  Para(body) => plain_inl(body)
  CodeBlock(_, code) => rtrim(code)
  Quote(bs) => plain(bs)
  List(_, _, _, items) => items.map(it => plain(it.blocks)).join("\n")
  Rule => ""
  Table(_, head, rows) => ([head] + rows).map(r => r.map(plain_inl).join("\t")).join("\n")
  HtmlBlock(_) => ""
}

fn plain_inl(xs: [Inline]): str = xs.map(x => match x {
  Text(s) => s
  Code(s) => s
  Em(b) => plain_inl(b)
  Strong(b) => plain_inl(b)
  Del(b) => plain_inl(b)
  Link(_, _, b) => plain_inl(b)
  Image(_, _, alt) => plain_inl(alt)
  SoftBreak => " "
  HardBreak => "\n"
  Html(_) => ""
}).join("")

// Named character references: the Latin-1 set (U+00A0..U+00FF in order) and other common ones.
let LATIN1 = "nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml".split()

// Each LATIN1 name's position.
let LATIN1_AT: {str: int} = latin1_at()

fn latin1_at(): {str: int} {
  var m: {str: int} = {}
  for k, n in LATIN1 {
    if m.get(n) == none { m[n] = k }
  }
  m
}

let ENTITIES = {
  "amp": "&",
  "lt": "<",
  "gt": ">",
  "quot": "\"",
  "apos": "'",
  "ndash": "–",
  "mdash": "—",
  "lsquo": "‘",
  "rsquo": "’",
  "sbquo": "‚",
  "ldquo": "“",
  "rdquo": "”",
  "bdquo": "„",
  "dagger": "†",
  "Dagger": "‡",
  "bull": "•",
  "hellip": "…",
  "permil": "‰",
  "prime": "′",
  "Prime": "″",
  "lsaquo": "‹",
  "rsaquo": "›",
  "euro": "€",
  "trade": "™",
  "larr": "←",
  "uarr": "↑",
  "rarr": "→",
  "darr": "↓",
  "harr": "↔",
  "hearts": "♥",
  "ensp": "\u{2002}",
  "emsp": "\u{2003}",
  "thinsp": "\u{2009}",
  "zwnj": "\u{200c}",
  "zwj": "\u{200d}",
  "OElig": "Œ",
  "oelig": "œ",
  "Scaron": "Š",
  "scaron": "š",
  "Yuml": "Ÿ",
  "fnof": "ƒ",
  "circ": "ˆ",
  "tilde": "˜",
  "minus": "−",
  "infin": "∞",
  "ne": "≠",
  "le": "≤",
  "ge": "≥",
  "asymp": "≈",
  "check": "✓",
}

// `&name;`, `&#123;` or `&#x7B;` as text, or none if it isn't a known reference.
fn decode_one(e: str): str? {
  let name = e[1..e.len() - 1]
  if name.starts_with("#") {
    let v = if name.starts_with("#x") || name.starts_with("#X") {
      hex_val(name[2..name.len()])?
    } else {
      int.parse(name[1..name.len()]) else { return none }
    }
    let cp = if v == 0 || v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff) { 0xfffd } else { v }
    return some(str([char(cp) else '\u{fffd}']))
  }
  match LATIN1_AT.get(name) {
    some(k) => some(str([char(0xa0 + k)!]))
    none => ENTITIES.get(name)
  }
}

fn decode_entities(s: str): str {
  if !s.contains("&") { return s }
  let cs = s.chars()
  let n = cs.len()
  var out = ""
  var a = 0  // start of the run not yet copied
  var i = 0
  while i < n {
    if cs[i] == '&' {
      match entity_len(cs, i) {
        some(m) => match decode_one(str(cs[i..i + m])) {
          some(r) => {
            if i > a { out += str(cs[a..i]) }
            out += r
            i += m
            a = i
            continue
          }
          none => {}
        }
        none => {}
      }
    }
    i += 1
  }
  if n > a { out += str(cs[a..n]) }
  out
}

fn hex_val(h: str): int? {
  var n = 0
  for c in h.lower().chars() {
    let d = "0123456789abcdef".find(str([c]))?
    n = n * 16 + d
  }
  some(n)
}

// ---- tests ----

fn md(s: str): str = html(s)
fn md_unsafe(s: str): str = html(s, Opts { unsafe_html: true })

test "blocks" {
  assert md("# Title\n\nSome *text*.\n") == "<h1>Title</h1>\n<p>Some <em>text</em>.</p>\n"
  assert md("Title\n=====\nSub\n---\n") == "<h1>Title</h1>\n<h2>Sub</h2>\n"
  assert md("## closed ##\n#5 no\n") == "<h2>closed</h2>\n<p>#5 no</p>\n"
  assert md("a\n\n***\n\nb") == "<p>a</p>\n<hr />\n<p>b</p>\n"
  assert md("> quote\nlazy\n\n> > nested") ==
    "<blockquote>\n<p>quote\nlazy</p>\n</blockquote>\n<blockquote>\n<blockquote>\n<p>nested</p>\n</blockquote>\n</blockquote>\n"
  assert md("    code\n      more\n\npara") ==
    "<pre><code>code\n  more\n</code></pre>\n<p>para</p>\n"
  assert md("```auk\nfn main() {{}}\n<x>\n```\n") ==
    "<pre><code class=\"language-auk\">fn main() {{}}\n&lt;x&gt;\n</code></pre>\n"
  assert md("~~~\nunclosed") == "<pre><code>unclosed\n</code></pre>\n"
  assert md("line one  \nline two\\\nthree\nfour") ==
    "<p>line one<br />\nline two<br />\nthree\nfour</p>\n"
}

test "lists" {
  assert md("- a\n- b\n") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"
  assert md("- a\n\n- b\n") == "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n"
  assert md("3. three\n4. four\n") == "<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>\n"
  assert md("- a\n  - b\n    - c\n- d") ==
    "<ul>\n<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>\n</ul>\n</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n"
  assert md("- a\n+ b\n") == "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n"
  assert md("1. x\n\n   ```\n   code\n   ```\n2. y") ==
    "<ol>\n<li>\n<p>x</p>\n<pre><code>code\n</code></pre>\n</li>\n<li>\n<p>y</p>\n</li>\n</ol>\n"
  // a list starting at a number other than 1 can't interrupt a paragraph
  assert md("The year\n1999. was good") == "<p>The year\n1999. was good</p>\n"
}

test "inlines" {
  assert md("*em* _em_ **strong** __strong__ ***both***") ==
    "<p><em>em</em> <em>em</em> <strong>strong</strong> <strong>strong</strong> <em><strong>both</strong></em></p>\n"
  assert md("snake_case_name and 2*3*4") == "<p>snake_case_name and 2<em>3</em>4</p>\n"
  assert md("`a < b` and `` x`y ``") == "<p><code>a &lt; b</code> and <code>x`y</code></p>\n"
  assert md("\\*not\\* \\# \\\\") == "<p>*not* # \\</p>\n"
  assert md("&copy; &#169; &#xA9; &bogus; \\&copy;") == "<p>© © © &amp;bogus; &amp;copy;</p>\n"
  assert md("a & b < c > \"d\"") == "<p>a &amp; b &lt; c &gt; &quot;d&quot;</p>\n"
}

test "links and images" {
  assert md("[auk](https://auk.dev \"Auk\")") ==
    "<p><a href=\"https://auk.dev\" title=\"Auk\">auk</a></p>\n"
  assert md("[a](<x y>) [b](/p(1))") == "<p><a href=\"x%20y\">a</a> <a href=\"/p(1)\">b</a></p>\n"
  assert md("![alt *text*](i.png)") == "<p><img src=\"i.png\" alt=\"alt text\" /></p>\n"
  assert md("[![img](i.png)](/to)") ==
    "<p><a href=\"/to\"><img src=\"i.png\" alt=\"img\" /></a></p>\n"
  let refs = "See [the docs][d], [Docs] and [d][].\n\n[d]: https://d.dev 'Title'\n[docs]: /docs\n"
  assert md(refs) ==
    "<p>See <a href=\"https://d.dev\" title=\"Title\">the docs</a>, <a href=\"/docs\">Docs</a> and <a href=\"https://d.dev\" title=\"Title\">d</a>.</p>\n"
  assert md("[nope] [x](") == "<p>[nope] [x](</p>\n"
  assert md("<https://a.dev/x> <me@a.dev>") ==
    "<p><a href=\"https://a.dev/x\">https://a.dev/x</a> <a href=\"mailto:me@a.dev\">me@a.dev</a></p>\n"
  assert md("[outer [inner](/i)](/o)") == "<p>[outer <a href=\"/i\">inner</a>](/o)</p>\n"
  assert md("[ü](/ü?q=a b)") == "<p>[ü](/ü?q=a b)</p>\n"
  assert md("[ü](/ü?q=a)") == "<p><a href=\"/%C3%BC?q=a\">ü</a></p>\n"
}

test "github extensions" {
  assert md("~~gone~~ ~one~ ~~~three~~~") == "<p><del>gone</del> <del>one</del> ~~~three~~~</p>\n"
  assert md("visit https://auk.dev/docs. or www.example.com, (https://x.dev/a_(b))") ==
    "<p>visit <a href=\"https://auk.dev/docs\">https://auk.dev/docs</a>. or <a href=\"http://www.example.com\">www.example.com</a>, (<a href=\"https://x.dev/a_(b)\">https://x.dev/a_(b)</a>)</p>\n"
  assert md("- [ ] todo\n- [x] done\n- [y] not a task") ==
    "<ul>\n<li><input disabled=\"\" type=\"checkbox\" /> todo</li>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\" /> done</li>\n<li>[y] not a task</li>\n</ul>\n"
  let t = "| Name | Qty |\n|:-----|----:|\n| auk | 2 |\n| a \\| b | `c` |\n| short |\n"
  assert md(t) == """
    <table>
    <thead>
    <tr>
    <th align="left">Name</th>
    <th align="right">Qty</th>
    </tr>
    </thead>
    <tbody>
    <tr>
    <td align="left">auk</td>
    <td align="right">2</td>
    </tr>
    <tr>
    <td align="left">a | b</td>
    <td align="right"><code>c</code></td>
    </tr>
    <tr>
    <td align="left">short</td>
    <td align="right"></td>
    </tr>
    </tbody>
    </table>
    """
  // the delimiter row must match the header's cell count
  assert md("| a | b |\n|---|\n") == "<p>| a | b |\n|---|</p>\n"
}

test "safety" {
  assert md("<script>alert(1)</script>") == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n"
  assert md("hi <img src=x onerror=alert(1)>") == "<p>hi &lt;img src=x onerror=alert(1)&gt;</p>\n"
  assert md("[x](javascript:alert(1)) [y](JavaScript:alert(1)) [z](vbscript:x)") ==
    "<p><a href=\"\">x</a> <a href=\"\">y</a> <a href=\"\">z</a></p>\n"
  assert md("![a](data:image/png;base64,AAAA) [b](data:text/html,x)") ==
    "<p><img src=\"data:image/png;base64,AAAA\" alt=\"a\" /> <a href=\"\">b</a></p>\n"
  assert md("[q](/a\"onmouseover=\"x)") == "<p><a href=\"/a%22onmouseover=%22x\">q</a></p>\n"
  // trusted input keeps its HTML
  assert md_unsafe("<div>\n*raw*\n</div>\n\nand <b>bold</b>") ==
    "<div>\n*raw*\n</div>\n<p>and <b>bold</b></p>\n"
  assert md_unsafe("[x](javascript:go())") == "<p><a href=\"javascript:go()\">x</a></p>\n"
  // `<!-->` and `<!--->` are complete comments (CommonMark 0.31), inline and as blocks
  assert md_unsafe("a <!--> b") == "<p>a <!--> b</p>\n"
  assert md_unsafe("a <!---> b") == "<p>a <!---> b</p>\n"
  assert md_unsafe("a <!--> b -->") == "<p>a <!--> b --&gt;</p>\n"
  assert md("a <!--> *b*") == "<p>a &lt;!--&gt; <em>b</em></p>\n"
  assert md_unsafe("<!-->\npara") == "<!-->\n<p>para</p>\n"
  assert md_unsafe("<!--->\npara") == "<!--->\n<p>para</p>\n"
}

test "tree and plain text" {
  let doc = parse("# Hi *there*\n\n- [x] a\n\n```\ncode\n```")
  assert doc.len() == 3
  assert doc[0] == Heading(1, [Text("Hi "), Em([Text("there")])])
  match doc[1] {
    List(false, 1, true, [Item { checked: some(true), blocks: [Para([Text("a")])] }]) => {}
    b => fail("unexpected {b}")
  }
  assert doc[2] == CodeBlock("", "code\n")
  assert text("# Title\n\nSome **bold** and [a link](/x) &amp; `code`.\n\n- one\n- two") ==
    "Title\n\nSome bold and a link & code.\n\none\ntwo"
}
