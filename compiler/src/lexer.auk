/// Source text -> tokens (src/lexer.rs). Besides splitting tokens, the lexer owns the newline
/// rule (which line breaks are significant), string interpolation, raw and triple-quoted
/// strings, escapes and bracket matching.

/// The tokens of a file (ending in `Eof`) and its module doc comment, if any.
pub struct Lexed { toks: [token.Token], module_doc: str? }

/// A string literal's text before it becomes `StrPart`s. Literal chars remember whether they
/// came from an escape, so dedenting only touches real indentation and line breaks.
enum Piece {
  PLit(cs: [(char, bool)]),
  PInterp(p: token.StrPart),
}

struct Lexer {
  chars: [char],
  pos: int,
  line: int,
  col: int,
  /// Pending `///` lines and the line number of the last one.
  docs: [str],
  doc_line: int,
  module_doc: str?,
  seen_token: bool,
  /// The previous token was `.` or `?.`, so digits are a tuple index (`t.0.1`), never a float.
  after_dot: bool,
  /// The previous token was a number literal or `int`/`float`, so a `<` right after it
  /// (no space) may start a unit (`3.0<m/s>`, `float<m>`).
  unit_ok: bool,
}

pub fn lex(src: str): Lexed!diag.Fail {
  var lx = Lexer {
    chars: src.chars(),
    pos: 0,
    line: 1,
    col: 1,
    docs: [],
    doc_line: 0,
    module_doc: none,
    seen_token: false,
    after_dot: false,
    unit_ok: false,
  }
  var raw: [(token.Token, bool)] = []
  loop {
    let (tok, nl) = next_token(&lx, none)?
    let eof = tok.tok == token.Eof
    raw.push((tok, nl))
    if eof { break }
  }
  let toks = insert_newlines(raw, [])?
  Lexed { toks, module_doc: lx.module_doc }
}

// ---- chars (Rust's char classes; Auk's are ASCII-only) ----

/// Unicode White_Space.
pub fn is_whitespace(c: char): bool {
  let n = int(c)
  if n < 0x80 { return n == 0x20 || (n >= 0x09 && n <= 0x0d) }
  n == 0x85 ||
    n == 0xa0 ||
    n == 0x1680 ||
    (n >= 0x2000 && n <= 0x200a) ||
    n == 0x2028 ||
    n == 0x2029 ||
    n == 0x202f ||
    n == 0x205f ||
    n == 0x3000
}

/// Rust's `char::is_alphabetic`, exact for ASCII; outside ASCII an approximation (letters are
/// assumed, except whitespace, Latin-1 punctuation and the general punctuation block).
pub fn is_alphabetic(c: char): bool {
  let n = int(c)
  if n < 0x80 { return (n >= 0x61 && n <= 0x7a) || (n >= 0x41 && n <= 0x5a) }
  if n < 0xc0 { return n == 0xaa || n == 0xb5 || n == 0xba }
  if n == 0xd7 || n == 0xf7 { return false }
  !is_whitespace(c) && !(n >= 0x2000 && n <= 0x2bff) && !(n >= 0x3000 && n <= 0x303f)
}

pub fn is_ascii_digit(c: char): bool = c >= '0' && c <= '9'

pub fn is_alphanumeric(c: char): bool = is_ascii_digit(c) || is_alphabetic(c)

fn is_hex_digit(c: char): bool =
  is_ascii_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

fn digit_value(c: char): int {
  if is_ascii_digit(c) { return int(c) - int('0') }
  if c >= 'a' && c <= 'z' { return int(c) - int('a') + 10 }
  if c >= 'A' && c <= 'Z' { return int(c) - int('A') + 10 }
  99
}

/// Rust's `char::is_digit(radix)`.
fn is_digit_radix(c: char, radix: int): bool = digit_value(c) < radix

// ---- the cursor ----

fn here(lx: Lexer): diag.Span =
  diag.Span { line: lx.line, col: lx.col, end_line: lx.line, end_col: lx.col }

/// From `start` to the current position.
fn from(lx: Lexer, start: diag.Span): diag.Span =
  diag.Span { end_line: lx.line, end_col: lx.col, ..start }

fn peek_at(lx: Lexer, n: int): char? = lx.chars.get(lx.pos + n)

fn peek(lx: Lexer): char? = lx.chars.get(lx.pos)

/// Is the char `n` ahead `c`?
fn is_at(lx: Lexer, n: int, c: char): bool =
  lx.pos + n < lx.chars.len() && lx.chars[lx.pos + n] == c

fn at_end(lx: Lexer): bool = lx.pos >= lx.chars.len()

fn bump(lx: var Lexer): char? {
  if lx.pos >= lx.chars.len() { return none }
  let c = lx.chars[lx.pos]
  lx.pos += 1
  if c == '\n' {
    lx.line += 1
    lx.col = 1
  } else {
    lx.col += 1
  }
  c
}

fn eat(lx: var Lexer, c: char): bool {
  if !lx.is_at(0, c) { return false }
  lx.bump()
  true
}

/// Skip whitespace and comments, collecting `///` docs. Returns (saw a line break, saw any
/// whitespace or comment).
fn skip_trivia(lx: var Lexer): (bool, bool)!diag.Fail {
  var nl = false
  var space = false
  loop {
    let c = lx.peek() else return (nl, space)
    if c == '\n' {
      nl = true
    } else if is_whitespace(c) {} else if c == '/' && lx.is_at(1, '/') {
      let doc = lx.is_at(2, '/') && !lx.is_at(3, '/')
      let line = lx.line
      let from = lx.pos
      while lx.pos < lx.chars.len() && lx.chars[lx.pos] != '\n' { lx.bump() }
      if doc {
        if lx.docs.len() > 0 && line != lx.doc_line + 1 { flush_docs(&lx) }
        // the text after `///`, less one leading space and any trailing whitespace
        var a = from + 3
        if a < lx.pos && lx.chars[a] == ' ' { a += 1 }
        var b = lx.pos
        while b > a && is_whitespace(lx.chars[b - 1]) { b -= 1 }
        lx.docs.push(str(lx.chars[a..b]))
        lx.doc_line = line
      }
      space = true
      continue
    } else if c == '/' && lx.is_at(1, '*') {
      let start = lx.here()
      lx.bump()
      lx.bump()
      var depth = 1
      while depth > 0 {
        match lx.bump() {
          none => fail(
            diag.Bad(
              diag.new(
                "E0003",
                start,
                "unterminated block comment",
              ).note("`/*` comments nest; every `/*` needs its own `*/`"),
            ),
          )
          some('\n') => nl = true
          some('/') => if lx.eat('*') { depth += 1 }
          some('*') => if lx.eat('/') { depth -= 1 }
          _ => {}
        }
      }
      space = true
      continue
    } else {
      return (nl, space)
    }
    space = true
    lx.bump()
  }
}

/// A doc block that no token directly follows: the module doc if nothing came before it,
/// otherwise dropped.
fn flush_docs(lx: var Lexer) {
  let docs = lx.docs
  lx.docs = []
  if !lx.seen_token && lx.module_doc == none { lx.module_doc = docs.join("\n") }
}

fn unclosed_interp(open: diag.Span): diag.Fail = diag.Bad(
  diag.new(
    "E0008",
    open,
    "unclosed `{{` in string interpolation",
  ).note("an interpolation is `{{expr}}` or `{{expr:spec}}`; write `{{{{` for a literal `{{`"),
)

/// The next token and whether a line break preceded it. Inside the interpolation opened at
/// `interp` in a one-line string, a line break or the end of the file means it was never
/// closed.
fn next_token(lx: var Lexer, interp: diag.Span?): (token.Token, bool)!diag.Fail {
  let (nl, space_before) = skip_trivia(&lx)?
  if interp is some(_) && (nl || lx.at_end()) { fail(unclosed_interp(interp!)) }
  let start = lx.here()
  // A block directly above a token is that token's doc; at the end of the file there is no
  // item to own it, so it is the module doc (or dropped).
  var doc: str? = none
  if lx.docs.len() > 0 && lx.doc_line + 1 == start.line && !lx.at_end() {
    doc = lx.docs.join("\n")
    lx.docs = []
  } else if lx.docs.len() > 0 {
    flush_docs(&lx)
  }
  if space_before { lx.unit_ok = false }
  let tok = token(&lx, start)?
  lx.after_dot = tok == token.Dot || tok == token.QuestionDot
  lx.unit_ok = match tok {
    Int(_) => true
    Float(_) => true
    Ident(n) => n == "int" || n == "float"
    _ => false
  }
  lx.seen_token = true
  (token.Token { tok, span: lx.from(start), doc, space_before }, nl)
}

fn token(lx: var Lexer, start: diag.Span): token.Tok!diag.Fail {
  let c = lx.bump() else return token.Eof
  match c {
    '(' => token.LParen
    ')' => token.RParen
    '[' => token.LBracket
    ']' => token.RBracket
    '{' => token.LBrace
    '}' => token.RBrace
    ',' => token.Comma
    ';' => {
      let span = lx.from(start)
      fail(
        diag.Bad(
          diag
            .new("E0011", span, "Auk does not use semicolons")
            .note("a line break ends a statement; put the next statement on its own line")
            .fix(span, ""),
        ),
      )
    }
    ':' => if lx.eat(':') { token.ColonColon } else { token.Colon }
    '.' => if lx.eat('.') {
      if lx.eat('=') { token.DotDotEq } else { token.DotDot }
    } else {
      token.Dot
    }
    '=' => if lx.eat('>') { token.FatArrow } else if lx.eat('=') { token.EqEq } else { token.Eq }
    '|' => if lx.eat('>') {
      token.PipeGt
    } else if lx.eat('|') {
      token.OrOr
    } else if lx.eat('=') {
      token.PipeEq
    } else {
      token.Pipe
    }
    '^' => if lx.eat('=') { token.CaretEq } else { token.Caret }
    '~' => token.Tilde
    '?' => if lx.eat('.') {
      token.QuestionDot
    } else if lx.eat('?') {
      token.QuestionQuestion
    } else {
      token.Question
    }
    '!' => if lx.eat('=') { token.BangEq } else { token.Bang }
    '&' => if lx.eat('&') { token.AndAnd } else if lx.eat('=') { token.AmpEq } else { token.Amp }
    '+' => if lx.eat('%') {
      token.PlusWrap
    } else if lx.eat('=') {
      token.PlusEq
    } else {
      token.Plus
    }
    '-' => if lx.eat('%') {
      token.MinusWrap
    } else if lx.eat('>') {
      token.Arrow
    } else if lx.eat('=') {
      token.MinusEq
    } else {
      token.Minus
    }
    '*' => if lx.eat('*') {
      token.StarStar
    } else if lx.eat('%') {
      token.StarWrap
    } else if lx.eat('=') {
      token.StarEq
    } else {
      token.Star
    }
    '/' => if lx.eat('=') { token.SlashEq } else { token.Slash }
    '%' => if lx.eat('=') { token.PercentEq } else { token.Percent }
    '<' => {
      let n = if lx.unit_ok { lx.unit_len() } else { none }
      match n {
        some(n) => {
          var cs: [char] = []
          for _ in 0..n {
            let c = lx.bump() else break
            cs.push(c)
          }
          lx.bump()
          token.Unit(str(cs).trim())
        }
        none => if lx.eat('<') {
          if lx.eat('=') { token.ShlEq } else { token.Shl }
        } else if lx.eat('=') {
          token.Le
        } else {
          token.Lt
        }
      }
    }
    '>' => if lx.eat('=') { token.Ge } else { token.Gt }
    '"' => string(&lx, start, false)?
    'r' when lx.is_at(0, '"') => {
      lx.bump()
      string(&lx, start, true)?
    }
    '\'' => char_lit(&lx, start)?
    _ when is_ascii_digit(c) => number(&lx, c, start)?
    _ when is_alphabetic(c) || c == '_' => {
      let from = lx.pos - 1
      while lx.pos < lx.chars.len() &&
        (is_alphanumeric(lx.chars[lx.pos]) || lx.chars[lx.pos] == '_') { lx.bump() }
      let s = str(lx.chars[from..lx.pos])
      token.keyword(s) else token.Ident(s)
    }
    _ => {
      var d = diag.new("E0001", lx.from(start), "unexpected character `{c}`")
      if c == '$' || c == '#' || c == '@' || c == '`' || c == '\\' {
        d = d.note("this character only appears inside strings and comments")
      }
      fail(diag.Bad(d))
    }
  }
}

/// Just after a `<` that directly follows a number or `int`/`float`: the length of a unit
/// before its closing `>`, if the rest of the line up to a `>` only has unit characters
/// (names, digits, spaces, `* / ^ -`). Anything else (`3<x && y > 2`) is a comparison.
fn unit_len(lx: Lexer): int? {
  var i = 0
  var name = false
  loop {
    let c = lx.peek_at(i)?
    if c == '>' { return if name { some(i) } else { none } }
    if is_alphanumeric(c) || c == '_' {
      name = true
    } else if c != ' ' && c != '*' && c != '/' && c != '^' && c != '-' {
      return none
    }
    i += 1
  }
}

fn number(lx: var Lexer, first: char, start: diag.Span): token.Tok!diag.Fail {
  var radix = 10
  if first == '0' && (lx.is_at(0, 'x') || lx.is_at(0, 'X')) {
    radix = 16
  } else if first == '0' && (lx.is_at(0, 'b') || lx.is_at(0, 'B')) {
    radix = 2
  }
  var s: [char] = []
  if radix == 10 {
    s.push(first)
  } else {
    lx.bump()
  }
  digits(&lx, &s, radix)
  var is_float = false
  if radix == 10 && !lx.after_dot {
    if lx.is_at(0, '.') && (lx.peek_at(1) is some(_)) && is_ascii_digit(lx.peek_at(1)!) {
      lx.bump()
      s.push('.')
      digits(&lx, &s, 10)
      is_float = true
    }
    var exp = false
    if lx.is_at(0, 'e') || lx.is_at(0, 'E') {
      let c1 = lx.peek_at(1) else ' '
      let c2 = lx.peek_at(2) else ' '
      exp = is_ascii_digit(c1) || (c1 == '+' || c1 == '-') && is_ascii_digit(c2)
    }
    if exp {
      s.push(lx.bump()!)
      if lx.is_at(0, '+') || lx.is_at(0, '-') { s.push(lx.bump()!) }
      digits(&lx, &s, 10)
      is_float = true
    }
  }
  match lx.peek() {
    some(c) when is_alphanumeric(c) || c == '_' => {
      let what = if radix == 16 { "a hex" } else if radix == 2 { "a binary" } else { "a number" }
      fail(
        diag.Bad(
          diag
            .new("E0004", lx.from(start), "invalid character `{c}` in {what} literal")
            .note("number literals look like `1_000`, `0xff`, `0b1010`, `3.14` or `1e-9`"),
        ),
      )
    }
    _ => {}
  }
  if s.len() == 0 {
    fail(
      diag.Bad(
        diag.new(
          "E0004",
          lx.from(start),
          "expected digits after the radix prefix",
        ).note("write e.g. `0xff` or `0b1010`"),
      ),
    )
  }
  if is_float { return token.Float(float.parse(str(s))!) }
  let n = parse_u64(s, radix) else fail(
    diag.Bad(
      diag
        .new("E0005", lx.from(start), "integer literal does not fit in 64 bits")
        .note("`int` is a 64-bit signed integer (at most 9_223_372_036_854_775_807)"),
    ),
  )
  token.Int(n)
}

/// The digits as an unsigned 64-bit number (its bits in an `int`), or none if it doesn't fit.
fn parse_u64(s: [char], radix: int): int? {
  var i = 0
  while i < s.len() - 1 && s[i] == '0' { i += 1 }
  let n = s.len() - i
  let max_digits = if radix == 16 { 16 } else if radix == 2 { 64 } else { 20 }
  if n > max_digits { return none }
  if radix == 10 && n == 20 && str(s[i..s.len()]) > "18446744073709551615" { return none }
  var v = 0
  while i < s.len() {
    v = v *% radix +% digit_value(s[i])
    i += 1
  }
  v
}

/// Digits of `radix`, skipping `_` separators.
fn digits(lx: var Lexer, s: var [char], radix: int) {
  while lx.pos < lx.chars.len() {
    let c = lx.chars[lx.pos]
    if is_digit_radix(c, radix) {
      s.push(c)
    } else if c != '_' {
      break
    }
    lx.bump()
  }
}

fn bad_escape(lx: Lexer, start: diag.Span, msg: str): diag.Fail = diag.Bad(
  diag.new(
    "E0006",
    lx.from(start),
    msg,
  ).note("valid escapes are \\n \\t \\r \\0 \\\\ \\\" \\' and \\u{{1F986}}; a raw string r\"...\" has none"),
)

/// After a `\`: one escape sequence.
fn escape(lx: var Lexer, start: diag.Span): char!diag.Fail {
  match lx.bump() {
    some('n') => '\n'
    some('t') => '\t'
    some('r') => '\r'
    some('0') => '\0'
    some('\\') => '\\'
    some('"') => '"'
    some('\'') => '\''
    some('u') => {
      if !lx.eat('{') {
        fail(bad_escape(lx, start, "expected `{{` after `\\u` (write `\\u{{1F986}}`)"))
      }
      var hex: [char] = []
      while lx.pos < lx.chars.len() && is_hex_digit(lx.chars[lx.pos]) {
        hex.push(lx.chars[lx.pos])
        lx.bump()
      }
      if hex.len() == 0 || hex.len() > 6 || !lx.eat('}') {
        fail(bad_escape(lx, start, "expected 1 to 6 hex digits and `}}` in `\\u{{...}}`"))
      }
      let n = parse_u64(hex, 16)!
      char(n) else fail(bad_escape(lx, start, "`\\u{{{str(hex)}}}` is not a Unicode scalar value"))
    }
    some(c) when c != '\n' => fail(bad_escape(lx, start, "unknown escape sequence `\\{c}`"))
    _ => fail(bad_escape(lx, start, "expected an escape sequence after `\\`"))
  }
}

fn char_lit(lx: var Lexer, start: diag.Span): token.Tok!diag.Fail {
  let c = match lx.peek() {
    some('\'') => {
      lx.bump()
      fail(
        diag.Bad(
          diag.new(
            "E0007",
            lx.from(start),
            "empty char literal",
          ).note("a char literal holds exactly one char, e.g. `'a'`"),
        ),
      )
    }
    some('\\') => {
      let at = lx.here()
      lx.bump()
      escape(&lx, at)?
    }
    some(c) when c != '\n' => {
      lx.bump()
      c
    }
    _ => fail(
      diag.Bad(
        diag.new(
          "E0007",
          lx.from(start),
          "unterminated char literal",
        ).note("close it with `'`, e.g. `'a'`"),
      ),
    )
  }
  if !lx.eat('\'') {
    var d = diag.new("E0007", lx.from(start), "expected `'` to close the char literal")
    var i = lx.pos
    while i < lx.chars.len() && lx.chars[i] != '\n' {
      if lx.chars[i] == '\'' {
        d = d.note("a char literal holds exactly one char; use double quotes for a string: \"...\"")
        break
      }
      i += 1
    }
    fail(diag.Bad(d))
  }
  token.Char(c)
}

/// After the opening `"` (or `r"`): a string literal. `"""` opens a triple-quoted string.
fn string(lx: var Lexer, start: diag.Span, raw: bool): token.Tok!diag.Fail {
  let triple = lx.is_at(0, '"') && lx.is_at(1, '"')
  if triple {
    lx.bump()
    lx.bump()
  }
  var pieces: [Piece] = []
  var lit: [(char, bool)] = []
  loop {
    let at = lx.here()
    let c = lx.peek() else {
      let close = if triple { "close it with `\"\"\"`" } else { "close it with `\"`" }
      fail(diag.Bad(diag.new("E0002", start, "unterminated string literal").note(close)))
    }
    if c == '\n' && !triple {
      fail(
        diag.Bad(
          diag
            .new("E0002", lx.from(start), "string literal is not closed on this line")
            .note("write `\\n` for a line break, or use a triple-quoted string \"\"\"...\"\"\""),
        ),
      )
    } else if c == '"' && !triple {
      lx.bump()
      break
    } else if c == '"' && lx.is_at(1, '"') && lx.is_at(2, '"') {
      lx.bump()
      lx.bump()
      lx.bump()
      break
    } else if c == '\\' && !raw {
      lx.bump()
      lit.push((escape(&lx, at)?, true))
    } else if c == '{' && !raw && lx.is_at(1, '{') {
      lx.bump()
      lx.bump()
      lit.push(('{', true))
    } else if c == '}' && !raw && lx.is_at(1, '}') {
      lx.bump()
      lx.bump()
      lit.push(('}', true))
    } else if c == '{' && !raw {
      pieces.push(PLit(lit))
      lit = []
      pieces.push(PInterp(interp(&lx, triple)?))
    } else if c == '}' && !raw {
      lx.bump()
      let span = lx.from(at)
      fail(
        diag.Bad(
          diag
            .new("E0009", span, "unmatched `}}` in a string")
            .note("write `}}}}` for a literal `}}` (and `{{{{` for `{{`)")
            .fix(span, "}}}}"),
        ),
      )
    } else {
      lx.bump()
      lit.push((c, false))
    }
  }
  pieces.push(PLit(lit))
  if triple { dedent(&pieces, lx.from(start))? }
  var parts: [token.StrPart] = []
  for p in pieces {
    match p {
      PLit(l) => if l.len() > 0 {
        let s = str(l.map(x => x.0))
        let n = parts.len()
        match parts.last() {
          some(Lit(prev)) => parts[n - 1] = token.Lit(prev + s)
          _ => parts.push(token.Lit(s))
        }
      }
      PInterp(i) => parts.push(i)
    }
  }
  token.Str(parts)
}

/// At the `{` of an interpolation: lex the expression up to the matching `}`, plus an
/// optional format spec after a `:` at the top nesting level (`{x:.2}`, `{i + 1:>2}`).
fn interp(lx: var Lexer, triple: bool): token.StrPart!diag.Fail {
  let open = lx.here()
  lx.bump()
  var raw: [(token.Token, bool)] = []
  var depth = 0
  var spec: str? = none
  loop {
    let (tok, nl) = next_token(&lx, if triple { none } else { some(open) })?
    match tok.tok {
      Eof => fail(unclosed_interp(open))
      LParen => depth += 1
      LBracket => depth += 1
      LBrace => depth += 1
      RParen => if depth > 0 { depth -= 1 }
      RBracket => if depth > 0 { depth -= 1 }
      RBrace when depth == 0 => break
      RBrace => depth -= 1
      Colon when depth == 0 => {
        var s: [char] = []
        loop {
          match lx.bump() {
            some('}') => break
            some(c) when c != '\n' && c != '"' => s.push(c)
            _ => fail(unclosed_interp(open))
          }
        }
        spec = str(s)
        break
      }
      _ => {}
    }
    raw.push((tok, nl))
  }
  let span = lx.from(open)
  if raw.len() == 0 {
    fail(
      diag.Bad(
        diag
          .new("E0008", span, "empty interpolation `{{}}` in a string")
          .note("put an expression inside, e.g. `{{name}}`, or write `{{{{}}}}` for literal braces")
          .fix(span, "{{{{}}}}"),
      ),
    )
  }
  let end = diag.Span { line: span.end_line, col: span.end_col - 1, ..span }
  raw.push((token.Token { tok: token.Eof, span: end, doc: none, space_before: false }, false))
  let toks = insert_newlines(raw, [('(', open)])?
  lx.after_dot = false
  token.Interp(toks, spec, span)
}

/// Apply the triple-quoted string rules: drop the line break right after the opening quotes,
/// and strip the closing line's indentation (when the closing quotes start their own line)
/// from every line.
fn dedent(pieces: var [Piece], span: diag.Span): ()!diag.Fail {
  var starts_with_newline = false
  match pieces[0] {
    PLit(l) => {
      var n = 0
      if l.len() >= 1 && l[0] == ('\n', false) {
        n = 1
      } else if l.len() >= 2 && l[0] == ('\r', false) && l[1] == ('\n', false) {
        n = 2
      }
      if n > 0 { pieces[0] = PLit(l.skip(n)) }
      starts_with_newline = n > 0
    }
    _ => {}
  }
  let li = pieces.len() - 1
  let last = match pieces[li] {
    PLit(l) => l
    _ => return
  }
  var nl = last.len() - 1
  while nl >= 0 && last[nl] != ('\n', false) { nl -= 1 }
  if nl < 0 { return }
  for k in nl + 1..last.len() {
    let (c, esc) = last[k]
    if esc || (c != ' ' && c != '\t') { return }
  }
  let indent = last.skip(nl + 1).map(x => x.0)
  pieces[li] = PLit(last.take(nl + 1))
  if indent.len() == 0 { return }
  let too_shallow = diag.Bad(
    diag
      .new(
        "E0010",
        span,
        "a line in this triple-quoted string is indented less than its closing `\"\"\"`",
      )
      .note("every line must start with the closing line's indentation ({indent.len()} chars), which is removed"),
  )
  // The first line keeps its text when it shares a line with the opening quotes.
  var line_start = starts_with_newline
  let n = pieces.len()
  for i in 0..n {
    match pieces[i] {
      PInterp(_) => if line_start { fail(too_shallow) }
      PLit(l) => {
        var out: [(char, bool)] = []
        var j = 0
        while j < l.len() {
          if line_start {
            line_start = false
            var k = 0
            while k < indent.len() && j + k < l.len() && !l[j + k].1 && l[j + k].0 == indent[k] {
              k += 1
            }
            let blank = if j + k < l.len() {
              let (c, esc) = l[j + k]
              c == '\n' && !esc || (c == '\r' && !esc)
            } else {
              i + 1 == n
            }
            if k < indent.len() && !blank { fail(too_shallow) }
            j += k
            continue
          }
          let (c, esc) = l[j]
          out.push((c, esc))
          line_start = c == '\n' && !esc
          j += 1
        }
        pieces[i] = PLit(out)
      }
    }
  }
}

/// A line break here can't end a statement because the line ends with this token.
fn continues_after(t: token.Tok): bool = match t {
  Plus => true
  Minus => true
  Star => true
  Slash => true
  Percent => true
  StarStar => true
  PlusWrap => true
  MinusWrap => true
  StarWrap => true
  EqEq => true
  BangEq => true
  Lt => true
  Le => true
  Gt => true
  Ge => true
  AndAnd => true
  OrOr => true
  DotDot => true
  DotDotEq => true
  PipeGt => true
  Eq => true
  PlusEq => true
  MinusEq => true
  StarEq => true
  SlashEq => true
  PercentEq => true
  Pipe => true
  Caret => true
  Tilde => true
  Shl => true
  AmpEq => true
  PipeEq => true
  CaretEq => true
  ShlEq => true
  FatArrow => true
  Arrow => true
  Comma => true
  Colon => true
  ColonColon => true
  Dot => true
  QuestionDot => true
  Amp => true
  LParen => true
  LBracket => true
  LBrace => true
  // keyword operators that need a right-hand side
  Is => true
  In => true
  Else => true
  When => true
  Uses => true
  Requires => true
  Ensures => true
  Await => true
  Catch => true
  _ => false
}

/// A line break here can't end a statement because the next line starts with this token.
fn continues_before(t: token.Tok): bool = match t {
  Dot => true
  PipeGt => true
  Requires => true
  Ensures => true
  LBrace => true
  _ => false
}

fn closer(open: char): char = match open {
  '(' => ')'
  '[' => ']'
  _ => '}'
}

/// Turn raw tokens (each flagged with "a line break came before it") into the final stream:
/// insert `Newline` where a statement can end, and check that brackets match.
///
/// A line break is significant only directly inside braces (a block is a statement list) or
/// at the top level; inside `(...)` and `[...]` it is always insignificant. Even there, the
/// line continues when it ends with an operator, `=`, `=>`, `,` or an open bracket, or when
/// the next line starts with `.`, `|>`, `requires`, `ensures` or `{`. `stack` holds the
/// brackets already open (an interpolation starts inside a virtual `(`).
fn insert_newlines(
  raw: [(token.Token, bool)],
  stack0: [(char, diag.Span)],
): [token.Token]!diag.Fail {
  var stack = stack0
  let base = stack.len()
  var out: [token.Token] = []
  for (tok, nl) in raw {
    if nl &&
      tok.tok != token.Eof &&
      (stack.len() == 0 || stack[stack.len() - 1].0 == '{') &&
      out.len() > 0 {
      let prev = out[out.len() - 1]
      if !continues_after(prev.tok) && !continues_before(tok.tok) {
        out.push(token.Token {
          tok: token.Newline,
          span: prev.span.after(),
          doc: none,
          space_before: false,
        })
      }
    }
    var open = ' '
    var want = ' '
    var close = ' '
    match tok.tok {
      LParen => open = '('
      LBracket => open = '['
      LBrace => open = '{'
      RParen => {
        want = '('
        close = ')'
      }
      RBracket => {
        want = '['
        close = ']'
      }
      RBrace => {
        want = '{'
        close = '}'
      }
      _ => {}
    }
    if open != ' ' {
      stack.push((open, tok.span))
    } else if close != ' ' {
      if stack.len() > base {
        let (o, at) = stack[stack.len() - 1]
        if o != want {
          fail(
            diag.Bad(
              diag
                .new(
                  "E0013",
                  tok.span,
                  "expected `{closer(o)}` to close the `{o}` at {at.show_at()}, found `{close}`",
                )
                .note("the `{o}` opened at {at.show_at()} is still open"),
            ),
          )
        }
        stack.pop()
      } else {
        fail(
          diag.Bad(
            diag.new(
              "E0013",
              tok.span,
              "unmatched `{close}`",
            ).note("there is no open `{want}` for it to close"),
          ),
        )
      }
    } else if tok.tok == token.Eof && stack.len() > base {
      let (o, at) = stack[stack.len() - 1]
      let before = if base == 0 { "the end of the file" } else { "the end of the interpolation" }
      fail(
        diag.Bad(
          diag.new(
            "E0012",
            at,
            "unclosed `{o}`",
          ).note("expected a `{closer(o)}` to close it before {before}"),
        ),
      )
    }
    out.push(tok)
  }
  out
}
