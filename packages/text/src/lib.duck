/// Text utilities: case conversion (snake, kebab, camel, pascal, title, constant), edit distance
/// and "did you mean" suggestions, terminal display width, POSIX shell-word splitting and
/// quoting, word wrapping, a line diff with unified output, indent/dedent and truncation.
/// Pure: no effects. Case mapping is ASCII-only; widths are per code point (no graphemes).

// ---- words and case ----

fn is_upper(c: char): bool = c >= 'A' && c <= 'Z'
fn is_lower(c: char): bool = c >= 'a' && c <= 'z'
fn is_digit(c: char): bool = c >= '0' && c <= '9'

// Part of a word: ASCII letters and digits, and every non-ASCII char except a few separators.
fn is_word(c: char): bool =
  is_upper(c) || is_lower(c) || is_digit(c) || (int(c) > 127 && !is_space(c) && c != '·')

fn is_space(c: char): bool =
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || int(c) == 0xa0 || int(c) == 0x3000

/// Splits an identifier or phrase into words, the way the case functions see it. Any char that
/// isn't a letter or digit separates words (`_ - . /` spaces ...). A word also ends before an
/// upper-case letter that follows a lower-case letter, a digit or a non-ASCII letter (`fooBar`,
/// `v2Api`, `caféAu`), and
/// before the last capital of an acronym followed by lower case (`XMLHttp` -> `XML`, `Http`).
/// Digits stay with the letters before them (`utf8Decode` -> `utf8`, `Decode`).
pub fn words(s: str): [str] {
  let cs = s.chars()
  var out: [str] = []
  var cur: [char] = []
  for i, c in cs {
    if !is_word(c) {
      if cur.len() > 0 { out.push(str(cur)) }
      cur = []
      continue
    }
    if cur.len() > 0 && is_upper(c) {
      let prev = cur[cur.len() - 1]
      let next_lower = i + 1 < cs.len() && is_lower(cs[i + 1])
      if is_lower(prev) || is_digit(prev) || int(prev) > 127 || (is_upper(prev) && next_lower) {
        out.push(str(cur))
        cur = []
      }
    }
    cur.push(c)
  }
  if cur.len() > 0 { out.push(str(cur)) }
  out
}

/// `First` letter upper case, the rest lower case (ASCII).
pub fn capitalize(w: str): str {
  let cs = w.chars()
  if cs.len() == 0 { return w }
  str([cs[0].upper()] + cs.skip(1).map(c => c.lower()))
}

/// `snake_case`: `snake("XMLHttpRequest") == "xml_http_request"`.
pub fn snake(s: str): str = words(s).map(w => w.lower()).join("_")
/// `kebab-case`: `kebab("fooBar baz") == "foo-bar-baz"`.
pub fn kebab(s: str): str = words(s).map(w => w.lower()).join("-")
/// `CONSTANT_CASE` (screaming snake): `constant("max size") == "MAX_SIZE"`.
pub fn constant(s: str): str = words(s).map(w => w.upper()).join("_")
/// `PascalCase`: `pascal("http_server") == "HttpServer"`.
pub fn pascal(s: str): str = words(s).map(capitalize).join("")
/// `Title Case`: `title("the_quick-brown fox") == "The Quick Brown Fox"`.
pub fn title(s: str): str = words(s).map(capitalize).join(" ")

/// `camelCase`: `camel("user_id") == "userId"`, `camel("HTTPServer") == "httpServer"`.
pub fn camel(s: str): str {
  let ws = words(s)
  match ws {
    [] => ""
    [first, ..rest] => first.lower() + rest.map(capitalize).join("")
  }
}

// ---- edit distance and suggestions ----

/// The Levenshtein distance: the fewest single-char insertions, deletions and substitutions
/// that turn `a` into `b`. Counts chars (code points), case-sensitive. O(len(a) * len(b)).
pub fn distance(a: str, b: str): int {
  let x = a.chars()
  let y = b.chars()
  if x.len() == 0 { return y.len() }
  if y.len() == 0 { return x.len() }
  var prev: [int] = []
  for j in 0..=y.len() { prev.push(j) }
  var cur = prev
  for i in 1..=x.len() {
    cur[0] = i
    for j in 1..=y.len() {
      let cost = if x[i - 1] == y[j - 1] { 0 } else { 1 }
      cur[j] = min3(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    }
    prev = cur
  }
  prev[y.len()]
}

fn min3(a: int, b: int, c: int): int {
  let m = if a < b { a } else { b }
  if m < c { m } else { c }
}

/// How alike two strings are, from 0.0 (nothing in common) to 1.0 (equal):
/// `1 - distance / max(len)`. Two empty strings are 1.0.
pub fn similarity(a: str, b: str): float {
  let n = a.len().max_len(b.len())
  if n == 0 { return 1.0 }
  1.0 - float(distance(a, b)) / float(n)
}

fn max_len(a: int, b: int): int = if a > b { a } else { b }

/// The options close enough to `s` to suggest, best first (at most `n`). Comparison ignores ASCII
/// case, and an option qualifies when its distance is at most a third of `s`'s length (at least
/// 1), as compilers do for "did you mean". Ties keep the options' order.
pub fn suggest(s: str, options: [str], n: int): [str] {
  let target = s.lower()
  let limit = s.len().max_len(3) / 3
  options
    .map(o => (distance(target, o.lower()), o))
    .filter(p => p.0 <= limit)
    .sort_by(p => p.0)
    .take(n)
    .map(p => p.1)
}

/// The single best suggestion for `s` among `options`, if any is close enough (see `suggest`):
/// `closest("stauts", ["status", "stash"]) == some("status")`.
pub fn closest(s: str, options: [str]): str? = suggest(s, options, 1).first()

// ---- display width ----

// Code point ranges, as hex `lo-hi` or a single `cp`, parsed at compile time into a flat
// sorted list `[lo0, hi0, lo1, hi1, ...]`.
fn parse_ranges(spec: str): [int] = spec.split().flat_map(r => match r.split("-") {
  [lo, hi] => [hex(lo), hex(hi)]
  _ => [hex(r), hex(r)]
})

fn hex(s: str): int = s.chars().reduce(0, (acc, c) => acc * 16 + hex_digit(c))

fn hex_digit(c: char): int {
  if is_digit(c) { return int(c) - int('0') }
  int(c.lower()) - int('a') + 10
}

// Zero width: combining marks, zero-width spaces and joiners, bidi controls, variation
// selectors, Hangul medial/final jamo, emoji skin-tone modifiers and tag characters.
imprint ZERO_WIDTH = parse_ranges("""
  0300-036F 0483-0489 0591-05BD 05BF 05C1-05C2 05C4-05C5 05C7 0610-061A 064B-065F 0670
  06D6-06DC 06DF-06E4 06E7-06E8 06EA-06ED 0711 0730-074A 07A6-07B0 07EB-07F3 0816-0819
  0900-0902 093A 093C 0941-0948 094D 0951-0957 0962-0963 0981 09BC 09C1-09C4 09CD 0A01-0A02
  0A3C 0A41-0A51 0E31 0E34-0E3A 0E47-0E4E 0EB1 0EB4-0EBC 0EC8-0ECD 0F18-0F19 0F35 0F37 0F39
  1160-11FF 135D-135F 1712-1714 17B4-17B5 17B7-17BD 17C6 17C9-17D3 180B-180F 1AB0-1AFF
  1DC0-1DFF 200B-200F 202A-202E 2060-2064 206A-206F 20D0-20FF 2CEF-2CF1 2DE0-2DFF 302A-302D
  3099-309A A66F-A672 A674-A67D A69E-A69F A6F0-A6F1 FB1E FE00-FE0F FE20-FE2F FEFF
  1F3FB-1F3FF E0000-E007F E0100-E01EF
  """)

// Two columns: East Asian Wide and Fullwidth (CJK, Hangul, kana, fullwidth forms) and emoji
// with default emoji presentation.
imprint WIDE = parse_ranges("""
  1100-115F 231A-231B 2329-232A 23E9-23EC 23F0 23F3 25FD-25FE 2614-2615 2648-2653 267F 2693
  26A1 26AA-26AB 26BD-26BE 26C4-26C5 26CE 26D4 26EA 26F2-26F3 26F5 26FA 26FD 2705 270A-270B
  2728 274C 274E 2753-2755 2757 2795-2797 27B0 27BF 2B1B-2B1C 2B50 2B55 2E80-303E 3041-33FF
  3400-4DBF 4E00-9FFF A000-A4CF A960-A97F AC00-D7A3 F900-FAFF FE10-FE19 FE30-FE6F FF00-FF60
  FFE0-FFE6 16FE0-16FE4 17000-18AFF 1B000-1B2FF 1F004 1F0CF 1F18E 1F191-1F19A 1F200-1F202
  1F210-1F23B 1F240-1F248 1F250-1F251 1F260-1F265 1F300-1F320 1F32D-1F335 1F337-1F37C
  1F37E-1F393 1F3A0-1F3CA 1F3CF-1F3D3 1F3E0-1F3F0 1F3F4 1F3F8-1F43E 1F440 1F442-1F4FC
  1F4FF-1F53D 1F54B-1F54E 1F550-1F567 1F57A 1F595-1F596 1F5A4 1F5FB-1F64F 1F680-1F6C5 1F6CC
  1F6D0-1F6D2 1F6D5-1F6D7 1F6DC-1F6DF 1F6EB-1F6EC 1F6F4-1F6FC 1F7E0-1F7EB 1F7F0 1F90C-1F93A
  1F93C-1F945 1F947-1F9FF 1FA70-1FAFF 20000-2FFFD 30000-3FFFD
  """)

fn in_ranges(rs: [int], cp: int): bool {
  var lo = 0
  var hi = rs.len() / 2
  while lo < hi {
    let mid = (lo + hi) / 2
    if cp < rs[2 * mid] {
      hi = mid
    } else if cp > rs[2 * mid + 1] {
      lo = mid + 1
    } else {
      return true
    }
  }
  false
}

/// The terminal columns one char takes: 0 for control chars, combining marks and other
/// zero-width code points; 2 for East Asian wide/fullwidth chars and most emoji; else 1.
pub fn char_width(c: char): int {
  let cp = int(c)
  if cp < 0x7f { return if cp < 0x20 { 0 } else { 1 } }
  if cp < 0xa0 { return 0 }  // DEL and C1 controls
  if cp < 0x300 { return 1 }
  if in_ranges(ZERO_WIDTH, cp) { return 0 }
  if in_ranges(WIDE, cp) { 2 } else { 1 }
}

/// The terminal columns `s` takes on one line (the sum of `char_width`): `width("日本") == 4`,
/// `width("e\u{301}") == 1`. An approximation: see the README for what it gets wrong.
pub fn width(s: str): int = s.chars().reduce(0, (acc, c) => acc + char_width(c))

/// `s` padded with spaces on the right to `w` columns (unchanged if already as wide), for
/// aligning tables that contain wide chars, where `"{s:<10}"` (which counts chars) would not.
pub fn pad_right(s: str, w: int): str = s + " ".repeat((w - width(s)).max_len(0))
/// `s` padded with spaces on the left to `w` columns.
pub fn pad_left(s: str, w: int): str = " ".repeat((w - width(s)).max_len(0)) + s

/// `s` cut to at most `w` columns, ending in `…` if anything was cut:
/// `truncate("hello world", 8) == "hello w…"`.
pub fn truncate(s: str, w: int): str = truncate(s, w, "…")

/// `s` cut to at most `w` columns, ending in `ellipsis` (e.g. `"..."`) if anything was cut. If
/// even the ellipsis doesn't fit, it is cut too.
pub fn truncate(s: str, w: int, ellipsis: str): str
  requires w >= 0
{
  if width(s) <= w { return s }
  let room = w - width(ellipsis)
  if room < 0 { return take_cols(ellipsis, w) }
  take_cols(s, room) + ellipsis
}

// The longest prefix of `s` that fits in `w` columns.
fn take_cols(s: str, w: int): str {
  var out: [char] = []
  var used = 0
  for c in s.chars() {
    let cw = char_width(c)
    if used + cw > w { break }
    used += cw
    out.push(c)
  }
  str(out)
}

// ---- shell words (POSIX sh quoting) ----

/// Why `shell_words` failed. `at` is the 0-based char index of the opening quote or backslash.
pub enum ShellErr {
  UnclosedQuote(at: int),      // a `'` or `"` with no closing match
  TrailingBackslash(at: int),  // a `\` as the very last char
}

/// A one-line description of an error, e.g. `unclosed quote at 4`.
pub fn message(e: ShellErr): str
fn message(UnclosedQuote(at)): str = "unclosed quote at {at}"
fn message(TrailingBackslash(at)): str = "backslash at end of input at {at}"

/// Splits a command line into words the way a POSIX shell does, without running anything:
/// whitespace separates words; `'...'` keeps everything literally; inside `"..."` a backslash
/// escapes only `$`, `` ` ``, `"`, `\` and newline; outside quotes `\` escapes any char, and
/// backslash-newline joins lines; `#` at the start of a word comments out the rest of the line.
/// Quotes can be glued to other text (`--name="a b"` is one word), and `""` is an empty word.
/// No expansion of any kind: `$x`, `*`, `~` and operators like `|` and `;` are ordinary chars.
pub fn shell_words(s: str): [str]!ShellErr {
  let cs = s.chars()
  let n = cs.len()
  var out: [str] = []
  var cur: [char] = []
  var in_word = false
  var i = 0
  while i < n {
    let c = cs[i]
    if c == ' ' || c == '\t' || c == '\n' {
      if in_word {
        out.push(str(cur))
        cur = []
        in_word = false
      }
      i += 1
    } else if c == '#' && !in_word {
      while i < n && cs[i] != '\n' { i += 1 }
    } else if c == '\\' {
      if i + 1 >= n { fail(TrailingBackslash(i)) }
      if cs[i + 1] != '\n' {
        cur.push(cs[i + 1])
        in_word = true
      }
      i += 2
    } else if c == '\'' {
      let start = i
      i += 1
      while i < n && cs[i] != '\'' {
        cur.push(cs[i])
        i += 1
      }
      if i >= n { fail(UnclosedQuote(start)) }
      in_word = true
      i += 1
    } else if c == '"' {
      let start = i
      i += 1
      while i < n && cs[i] != '"' {
        if cs[i] == '\\' && i + 1 < n && "$`\"\\\n".contains(cs[i + 1]) {
          if cs[i + 1] != '\n' { cur.push(cs[i + 1]) }
          i += 2
        } else {
          cur.push(cs[i])
          i += 1
        }
      }
      if i >= n { fail(UnclosedQuote(start)) }
      in_word = true
      i += 1
    } else {
      cur.push(c)
      in_word = true
      i += 1
    }
  }
  if in_word { out.push(str(cur)) }
  out
}

fn is_shell_safe(c: char): bool =
  is_upper(c) || is_lower(c) || is_digit(c) || "@%+=:,./_-".contains(c)

/// `s` quoted for a POSIX shell so it reads back as exactly one word: unchanged if it's made of
/// safe chars only (`a-z A-Z 0-9 @%+=:,./_-`), else single-quoted, with `'` written as `'"'"'`.
/// `shell_words(quote(s)) == [s]` for every `s`.
pub fn quote(s: str): str {
  if s.len() > 0 && s.chars().all(is_shell_safe) { return s }
  "'" + s.replace("'", "'\"'\"'") + "'"
}

/// Words quoted and joined by spaces into one command line: the inverse of `shell_words`.
pub fn join(ws: [str]): str = ws.map(quote).join(" ")

// ---- wrapping, indentation ----

/// Word-wraps text to lines of at most `w` columns (by `width`). Each input line is wrapped on
/// its own, so existing line breaks and blank lines are kept; runs of spaces between words
/// collapse to one, and leading indentation is dropped. A word wider than `w` is split.
pub fn wrap(s: str, w: int): [str]
  requires w > 0
{
  var out: [str] = []
  for line in s.split("\n") {
    let ws = line.split()
    if ws.len() == 0 {
      out.push("")
      continue
    }
    let first = out.len()
    var cur = ""
    var used = 0
    for word in ws {
      var rest = word
      var ww = width(rest)
      if used > 0 && used + 1 + ww <= w {
        cur = cur + " " + rest
        used += 1 + ww
        continue
      }
      if used > 0 {
        out.push(cur)
        cur = ""
        used = 0
      }
      while ww > w {
        let head = take_cols(rest, w)
        let head = if head.len() == 0 { rest[0..1] } else { head }  // a 2-column char at w = 1
        out.push(head)
        rest = rest[head.len()..rest.len()]
        ww = width(rest)
      }
      cur = rest
      used = ww
    }
    if used > 0 || out.len() == first { out.push(cur) }
  }
  out
}

/// `wrap` joined with newlines.
pub fn fill(s: str, w: int): str = wrap(s, w).join("\n")

/// Every non-blank line of `s` with `prefix` in front (blank lines stay empty).
pub fn indent(s: str, prefix: str): str =
  s.split("\n").map(l => if l.trim().len() == 0 { l } else { prefix + l }).join("\n")

/// Removes the leading whitespace that all non-blank lines share, and empties whitespace-only
/// lines: for text in triple-quoted or indented source. Tabs and spaces must match exactly.
pub fn dedent(s: str): str {
  let lines = s.split("\n")
  var common: str? = none
  for l in lines {
    if l.trim().len() == 0 { continue }
    let lead = leading_ws(l)
    common = match common {
      none => some(lead)
      some(c) => some(shared_prefix(c, lead))
    }
  }
  let cut = (common else "").len()
  lines.map(l => if l.trim().len() == 0 { "" } else { l[cut..l.len()] }).join("\n")
}

fn leading_ws(l: str): str {
  let cs = l.chars()
  let n = cs.find_index(c => c != ' ' && c != '\t') else cs.len()
  str(cs.take(n))
}

fn shared_prefix(a: str, b: str): str {
  let x = a.chars()
  let y = b.chars()
  var i = 0
  while i < x.len() && i < y.len() && x[i] == y[i] { i += 1 }
  str(x.take(i))
}

// ---- line diff (Myers) ----

/// One step of a diff: a line both sides share, a line only in the old text, or one only in the
/// new text.
pub enum Edit { Keep(line: str), Del(line: str), Ins(line: str) }

/// The shortest edit script from `old` to `new` (lists of lines): Myers' O(ND) algorithm, so it
/// is fast when the inputs are similar. Deletions come before insertions within a change.
pub fn diff(old: [str], new: [str]): [Edit] {
  // common prefix and suffix are kept as-is; Myers runs on the middle
  var pre = 0
  while pre < old.len() && pre < new.len() && old[pre] == new[pre] { pre += 1 }
  var suf = 0
  while suf < old.len() - pre &&
    suf < new.len() - pre &&
    old[old.len() - 1 - suf] == new[new.len() - 1 - suf] {
    suf += 1
  }
  let a = old[pre..old.len() - suf]
  let b = new[pre..new.len() - suf]
  var out: [Edit] = old.take(pre).map(l => Keep(l))
  out = out + myers(a, b)
  out + old.skip(old.len() - suf).map(l => Keep(l))
}

fn myers(a: [str], b: [str]): [Edit] {
  let n = a.len()
  let m = b.len()
  if n == 0 { return b.map(l => Ins(l)) }
  if m == 0 { return a.map(l => Del(l)) }
  let max = n + m
  let off = max + 1
  var v: [int] = []
  for _ in 0..2 * max + 3 { v.push(0) }
  // trace[d] = v[off - d - 1 ..= off + d + 1] as it was before round d
  var trace: [[int]] = []
  var done = -1
  for d in 0..=max {
    trace.push(v[off - d - 1..off + d + 2])
    var k = -d
    while k <= d {
      var x = if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) {
        v[off + k + 1]
      } else {
        v[off + k - 1] + 1
      }
      var y = x - k
      while x < n && y < m && a[x] == b[y] {
        x += 1
        y += 1
      }
      v[off + k] = x
      if x >= n && y >= m {
        done = d
        break
      }
      k += 2
    }
    if done >= 0 { break }
  }
  // walk back from (n, m), collecting edits in reverse
  var rev: [Edit] = []
  var x = n
  var y = m
  var d = done
  while d >= 0 {
    let t = trace[d]
    let at = (kk: int) => t[kk + d + 1]  // v[kk] in round d
    let k = x - y
    let pk = if k == -d || (k != d && at(k - 1) < at(k + 1)) { k + 1 } else { k - 1 }
    let px = at(pk)
    let py = px - pk
    while x > px && y > py {
      rev.push(Keep(a[x - 1]))
      x -= 1
      y -= 1
    }
    if d > 0 {
      if x == px {
        rev.push(Ins(b[y - 1]))
        y -= 1
      } else {
        rev.push(Del(a[x - 1]))
        x -= 1
      }
    }
    d -= 1
  }
  // within each change, list deletions before insertions
  tidy(rev.reverse())
}

fn tidy(es: [Edit]): [Edit] {
  var out: [Edit] = []
  var dels: [Edit] = []
  var ins: [Edit] = []
  for e in es {
    match e {
      Keep(_) => {
        out = out + dels + ins + [e]
        dels = []
        ins = []
      }
      Del(_) => dels.push(e)
      Ins(_) => ins.push(e)
    }
  }
  out + dels + ins
}

// Lines with their "\n" kept, so a missing final newline counts as a difference.
fn raw_lines(s: str): [str] {
  if s.len() == 0 { return [] }
  let parts = s.split("\n")
  var out: [str] = []
  for i, p in parts {
    if i < parts.len() - 1 {
      out.push(p + "\n")
    } else if p.len() > 0 {
      out.push(p)
    }
  }
  out
}

/// A unified diff (`diff -u` hunks, 3 lines of context) from `old` to `new`, or `""` if they
/// are equal. Only the `@@` hunks: prepend `--- a/file\n+++ b/file\n` for a patch.
pub fn unified(old: str, new: str): str = unified(old, new, 3)

/// A unified diff with `context` unchanged lines around each change. Hunks closer than
/// `2 * context` lines merge. A last line without a newline is marked
/// `\ No newline at end of file`, as GNU diff and git do.
pub fn unified(old: str, new: str, context: int): str
  requires context >= 0
{
  let es = diff(raw_lines(old), raw_lines(new))
  let changed = es.enum().filter(p => !(p.1 is Keep(_))).map(p => p.0)
  if changed.len() == 0 { return "" }
  // group change positions into hunks [from, to) over `es`
  var hunks: [(int, int)] = []
  var start = changed[0]
  var last = changed[0]
  for i in changed.skip(1) {
    if i - last - 1 > 2 * context {
      hunks.push((start, last))
      start = i
    }
    last = i
  }
  hunks.push((start, last))
  // line numbers before each edit
  var olds: [int] = []
  var news: [int] = []
  var o = 0
  var nn = 0
  for e in es {
    olds.push(o)
    news.push(nn)
    match e {
      Keep(_) => {
        o += 1
        nn += 1
      }
      Del(_) => o += 1
      Ins(_) => nn += 1
    }
  }
  var out: [str] = []
  for (first, lastc) in hunks {
    let from = (first - context).max_len(0)
    let to = (lastc + context + 1).min_len(es.len())
    let part = es[from..to]
    let oc = part.filter(e => !(e is Ins(_))).len()
    let nc = part.filter(e => !(e is Del(_))).len()
    out.push("@@ -{range(olds[from], oc)} +{range(news[from], nc)} @@\n")
    for e in part {
      match e {
        Keep(l) => out.push(" " + newline(l))
        Del(l) => out.push("-" + newline(l))
        Ins(l) => out.push("+" + newline(l))
      }
    }
  }
  out.join("")
}

fn min_len(a: int, b: int): int = if a < b { a } else { b }

// A hunk range: 1-based start and count; `start` alone when the count is 1, and the line
// before the hunk when it is empty.
fn range(before: int, count: int): str {
  if count == 0 { return "{before},0" }
  if count == 1 { return "{before + 1}" }
  "{before + 1},{count}"
}

fn newline(l: str): str = if l.ends_with("\n") { l } else { l + "\n\\ No newline at end of file\n" }

// ---- tests ----

test "words" {
  assert words("fooBar") == ["foo", "Bar"]
  assert words("XMLHttpRequest") == ["XML", "Http", "Request"]
  assert words("HTTPServer") == ["HTTP", "Server"]
  assert words("utf8Decode") == ["utf8", "Decode"]
  assert words("v2Api") == ["v2", "Api"]
  assert words("  hello__world--again. ") == ["hello", "world", "again"]
  assert words("user.id/name") == ["user", "id", "name"]
  assert words("ABC") == ["ABC"]
  assert words("aB") == ["a", "B"]
  assert words("") == [] && words("--") == []
  assert words("caféAu lait") == ["café", "Au", "lait"]
}

test "case conversion" {
  // input | snake | kebab | camel | pascal | title | constant
  let rows = [
    "XMLHttpRequest|xml_http_request|xml-http-request|xmlHttpRequest|XmlHttpRequest|Xml Http Request|XML_HTTP_REQUEST",
    "user_id|user_id|user-id|userId|UserId|User Id|USER_ID",
    "the quick-brown FOX|the_quick_brown_fox|the-quick-brown-fox|theQuickBrownFox|TheQuickBrownFox|The Quick Brown Fox|THE_QUICK_BROWN_FOX",
    "getHTTPResponseCode|get_http_response_code|get-http-response-code|getHttpResponseCode|GetHttpResponseCode|Get Http Response Code|GET_HTTP_RESPONSE_CODE",
    "MAX_SIZE|max_size|max-size|maxSize|MaxSize|Max Size|MAX_SIZE",
    "base64Url|base64_url|base64-url|base64Url|Base64Url|Base64 Url|BASE64_URL",
    "||||||",
  ]
  for row in rows {
    let [s, sn, ke, ca, pa, ti, co] = row.split("|") else fail("bad row {row}")
    assert snake(s) == sn
    assert kebab(s) == ke
    assert camel(s) == ca
    assert pascal(s) == pa
    assert title(s) == ti
    assert constant(s) == co
  }
  // converting twice is stable
  for s in ["fooBarBaz", "foo_bar_baz", "Foo Bar Baz"] {
    assert snake(camel(s)) == "foo_bar_baz" && camel(snake(s)) == "fooBarBaz"
  }
  assert capitalize("hELLO") == "Hello" && capitalize("") == ""
}

test "distance and similarity" {
  assert distance("kitten", "sitting") == 3
  assert distance("flaw", "lawn") == 2
  assert distance("", "abc") == 3 && distance("abc", "") == 3 && distance("", "") == 0
  assert distance("same", "same") == 0
  assert distance("abc", "ABC") == 3  // case-sensitive
  assert distance("日本語", "日本") == 1   // chars, not bytes
  assert distance("saturday", "sunday") == 3
  assert similarity("", "") == 1.0
  assert similarity("abc", "abc") == 1.0
  assert similarity("abc", "xyz") == 0.0
  assert similarity("kitten", "sitting") == 1.0 - 3.0 / 7.0
}

test "closest and suggest" {
  let cmds = ["status", "stash", "commit", "checkout", "cherry-pick", "push", "pull"]
  assert closest("stauts", cmds) == some("status")
  assert closest("comit", cmds) == some("commit")
  assert closest("PUSH", cmds) == some("push")  // case-insensitive
  assert closest("xyzzy", cmds) == none
  assert closest("", cmds) == none
  assert closest("a", []) == none
  assert suggest("pusl", cmds, 5) == ["push", "pull"]  // equal distance: input order
  assert suggest("pusl", cmds, 1) == ["push"]
  assert suggest("pul", cmds, 5) == ["pull"]  // "push" is 2 edits away: too far for 3 chars
  assert suggest("chekout", cmds, 5) == ["checkout"]
}

test "display width" {
  assert width("hello") == 5 && width("") == 0
  assert width("日本語") == 6
  assert width("한국어") == 6
  assert width("ｶﾀｶﾅ") == 4                   // halfwidth katakana is narrow
  assert width("ＡＢ") == 4                     // fullwidth Latin
  assert width("e\u{301}") == 1               // combining acute
  assert width("🦆") == 2 && width("👍🏽") == 2  // emoji, skin tone modifier
  assert width("❤") == 1 && width("✅") == 2   // text-default vs emoji-default presentation
  assert width("a\u{200b}b") == 2             // zero-width space
  assert width("\t\u{7}") == 0                // controls
  assert width("café") == 4 && width("Ω") == 1
  assert char_width('中') == 2 && char_width('a') == 1 && char_width('\u{fe0f}') == 0
  assert char_width('\u{20000}') == 2  // CJK extension B
}

test "padding and truncation" {
  assert pad_right("日本", 6) == "日本  " && pad_left("ab", 4) == "  ab"
  assert pad_right("toolong", 3) == "toolong"
  assert truncate("hello world", 8) == "hello w…"
  assert truncate("hello", 5) == "hello"
  assert truncate("hello", 4) == "hel…"
  assert truncate("hello world", 8, "...") == "hello..."
  assert truncate("日本語テキスト", 7) == "日本語…"  // never splits a wide char
  assert width(truncate("日本語テキスト", 7)) == 7
  assert truncate("hello", 0) == ""
  assert truncate("hello", 2, "...") == ".."
}

test "shell_words: POSIX quoting" {
  assert shell_words("ls -la /tmp")? == ["ls", "-la", "/tmp"]
  assert shell_words("  a \t b\n c  ")? == ["a", "b", "c"]
  assert shell_words("")? == [] && shell_words("   ")? == []
  assert shell_words("echo 'hello world'")? == ["echo", "hello world"]
  assert shell_words("echo \"hello world\"")? == ["echo", "hello world"]
  assert shell_words("--name=\"a b\"c'd e'")? == ["--name=a bcd e"]
  assert shell_words("'' \"\" x")? == ["", "", "x"]
  assert shell_words("a\\ b c")? == ["a b", "c"]
  assert shell_words("'it'\\''s'")? == ["it's"]
  assert shell_words("'a\\b'")? == ["a\\b"]  // no escapes inside single quotes
  assert shell_words("\"a\\\"b\\\\c\\$d\\`e\"")? == ["a\"b\\c$d`e"]
  assert shell_words("\"a\\nb\"")? == ["a\\nb"]  // other backslashes stay in double quotes
  assert shell_words("\\$HOME \\*")? == ["$HOME", "*"]
  assert shell_words("$HOME *.txt ~ a|b;c")? == ["$HOME", "*.txt", "~", "a|b;c"]  // no expansion
  assert shell_words("one \\\ntwo")? == ["one", "two"]                            // line continuation
  assert shell_words("a\\\nb")? == ["ab"]
  assert shell_words("\"a\\\nb\"")? == ["ab"]
  assert shell_words("echo hi # a comment\nls")? == ["echo", "hi", "ls"]
  assert shell_words("a#b '#c' \"#d\"")? == ["a#b", "#c", "#d"]  // # only starts a word
  assert shell_words("é 日本 '🦆'")? == ["é", "日本", "🦆"]
}

test "shell_words: errors" {
  assert shell_words("echo 'oops") is err(UnclosedQuote(5))
  assert shell_words("echo \"oops") is err(UnclosedQuote(5))
  assert shell_words("a \"b\\\"") is err(UnclosedQuote(2))
  assert shell_words("trailing\\") is err(TrailingBackslash(8))
  assert message(UnclosedQuote(5)) == "unclosed quote at 5"
}

test "quote and join round-trip" {
  assert quote("simple-name_1.txt") == "simple-name_1.txt"
  assert quote("") == "''"
  assert quote("a b") == "'a b'"
  assert quote("it's") == "'it'\"'\"'s'"
  assert quote("$HOME") == "'$HOME'"
  assert join(["git", "commit", "-m", "fix: it's done"]) == "git commit -m 'fix: it'\"'\"'s done'"
  let tricky = ["", " ", "'", "\"", "\\", "a\nb", "#x", "$(rm -rf /)", "*", "日本", "--x='y'"]
  for s in tricky { assert shell_words(quote(s))? == [s] }
  assert shell_words(join(tricky))? == tricky
}

test "wrap and fill" {
  assert wrap("the quick brown fox jumps over the lazy dog", 10) ==
    ["the quick", "brown fox", "jumps over", "the lazy", "dog"]
  assert wrap("short", 10) == ["short"]
  assert wrap("", 10) == [""]
  assert wrap("a  b   c", 10) == ["a b c"]
  assert wrap("para one\n\npara two", 20) == ["para one", "", "para two"]
  assert wrap("abcdefghij", 4) == ["abcd", "efgh", "ij"]  // long words are split
  assert wrap("hi abcdefghij x", 4) == ["hi", "abcd", "efgh", "ij x"]
  assert wrap("日本語のテキスト", 6) == ["日本語", "のテキ", "スト"]
  assert wrap("日本", 1) == ["日", "本"]  // a wide char always makes progress
  assert fill("aaa bbb ccc", 7) == "aaa bbb\nccc"
  for line in wrap("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do", 12) {
    assert width(line) <= 12
  }
}

test "indent and dedent" {
  assert indent("a\nb", "  ") == "  a\n  b"
  assert indent("a\n\nb\n", "> ") == "> a\n\n> b\n"
  assert dedent("    a\n      b\n    c") == "a\n  b\nc"
  assert dedent("\n    a\n\n    b\n") == "\na\n\nb\n"
  assert dedent("  a\n    \n  b") == "a\n\nb"  // whitespace-only lines are emptied
  assert dedent("\ta\n\t\tb") == "a\n\tb"
  assert dedent("  a\n\tb") == "  a\n\tb"  // mixed tabs and spaces share nothing
  assert dedent("no indent\n  x") == "no indent\n  x"
  assert dedent(indent("x\n  y", "    ")) == "x\n  y"
}

fn show_edits(es: [Edit]): str = es
  .map(e => match e {
    Keep(l) => " " + l
    Del(l) => "-" + l
    Ins(l) => "+" + l
  })
  .join("|")

test "diff: edit scripts" {
  assert diff([], []) == []
  assert show_edits(diff(["a", "b", "c"], ["a", "b", "c"])) == " a| b| c"
  assert show_edits(diff([], ["x"])) == "+x"
  assert show_edits(diff(["x"], [])) == "-x"
  assert show_edits(diff(["a", "b", "c"], ["a", "x", "c"])) == " a|-b|+x| c"
  // the classic Myers example: ABCABBA -> CBABAC has 5 edits and 4 common lines
  let a = "ABCABBA".chars().map(c => "{c}")
  let b = "CBABAC".chars().map(c => "{c}")
  let es = diff(a, b)
  assert es.filter(e => e is Keep(_)).len() == 4
  assert es.filter(e => !(e is Keep(_))).len() == 5
  // applying the script gives back both sides
  for (x, y) in [(a, b), (b, a), (["1", "2", "3", "4"], ["0", "2", "4", "5"]), ([], a)] {
    let e = diff(x, y)
    assert e.flat_map(s => match s {
      Keep(l) => [l]
      Del(l) => [l]
      Ins(_) => []
    }) ==
      x
    assert e.flat_map(s => match s {
      Keep(l) => [l]
      Ins(l) => [l]
      Del(_) => []
    }) ==
      y
  }
}

test "unified diff" {
  assert unified("a\nb\n", "a\nb\n") == ""
  assert unified("a\nb\nc\n", "a\nx\nc\n") == "@@ -1,3 +1,3 @@\n a\n-b\n+x\n c\n"
  assert unified("", "new\n") == "@@ -0,0 +1 @@\n+new\n"
  assert unified("old\n", "") == "@@ -1 +0,0 @@\n-old\n"
  // context trimmed to 3 lines, and far-apart changes get separate hunks
  let old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n"
  let new = "1\n2\nthree\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\nfourteen\n15\n"
  assert unified(old, new) ==
    "@@ -1,6 +1,6 @@\n 1\n 2\n-3\n+three\n 4\n 5\n 6\n@@ -11,5 +11,5 @@\n 11\n 12\n 13\n-14\n+fourteen\n 15\n"
  // with more context the two hunks merge
  assert unified(old, new, 6).split("@@ -").len() == 2
  assert unified(old, new, 0) == "@@ -3 +3 @@\n-3\n+three\n@@ -14 +14 @@\n-14\n+fourteen\n"
  // pure insertion with zero context: the range names the line before
  assert unified("a\nb\n", "a\nx\nb\n", 0) == "@@ -1,0 +2 @@\n+x\n"
  // a missing final newline is a change of its own
  assert unified("a\nb", "a\nb\n") == "@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+b\n"
  assert unified("x", "y") ==
    "@@ -1 +1 @@\n-x\n\\ No newline at end of file\n+y\n\\ No newline at end of file\n"
}

test "diff: larger inputs stay fast" {
  var a: [str] = []
  for i in 0..3000 { a.push("line {i}") }
  var b = a
  b[10] = "changed"
  b.insert(1500, "inserted")
  b.remove(2900)
  let es = diff(a, b)
  assert es.filter(e => !(e is Keep(_))).len() == 4
  let u = unified(a.join("\n") + "\n", b.join("\n") + "\n")
  assert u.split("@@ -").len() == 4
}
