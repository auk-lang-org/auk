//! Source text -> tokens. Besides splitting tokens, the lexer owns the newline rule (which line
//! breaks are significant), string interpolation, raw and triple-quoted strings, escapes and
//! bracket matching.

use super::diag::{Diag, Span};
use super::token::{StrPart, Tok, Token, keyword};

/// The tokens of a file (ending in `Eof`) and its module doc comment, if any.
#[derive(Debug)]
pub struct Lexed {
    pub toks: Vec<Token>,
    /// A `///` block at the very top of the file that is not directly above the first token.
    pub module_doc: Option<String>,
}

pub fn lex(src: &str) -> Result<Lexed, Diag> {
    let mut lx = Lexer {
        chars: src.chars().collect(),
        pos: 0,
        line: 1,
        col: 1,
        docs: Vec::new(),
        doc_line: 0,
        module_doc: None,
        seen_token: false,
        after_dot: false,
        unit_ok: false,
    };
    let mut raw = Vec::new();
    loop {
        let (tok, nl) = lx.next_token(None)?;
        let eof = tok.tok == Tok::Eof;
        raw.push((tok, nl));
        if eof {
            break;
        }
    }
    let toks = insert_newlines(raw, Vec::new())?;
    Ok(Lexed { toks, module_doc: lx.module_doc })
}

/// A string literal's text before it becomes `StrPart`s. Literal chars remember whether they
/// came from an escape, so dedenting only touches real indentation and line breaks.
enum Piece {
    Lit(Vec<(char, bool)>),
    Interp(StrPart),
}

struct Lexer {
    chars: Vec<char>,
    pos: usize,
    line: u32,
    col: u32,
    /// Pending `///` lines and the line number of the last one.
    docs: Vec<String>,
    doc_line: u32,
    module_doc: Option<String>,
    seen_token: bool,
    /// The previous token was `.` or `?.`, so digits are a tuple index (`t.0.1`), never a float.
    after_dot: bool,
    /// The previous token was a number literal or `int`/`float`, so a `<` right after it
    /// (no space) may start a unit (`3.0<m/s>`, `float<m>`).
    unit_ok: bool,
}

impl Lexer {
    fn here(&self) -> Span {
        Span { line: self.line, col: self.col, end_line: self.line, end_col: self.col }
    }

    /// From `start` to the current position.
    fn from(&self, start: Span) -> Span {
        Span { end_line: self.line, end_col: self.col, ..start }
    }

    fn peek_at(&self, n: usize) -> Option<char> {
        self.chars.get(self.pos + n).copied()
    }

    fn peek(&self) -> Option<char> {
        self.peek_at(0)
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.pos += 1;
        if c == '\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        Some(c)
    }

    fn eat(&mut self, c: char) -> bool {
        let yes = self.peek() == Some(c);
        if yes {
            self.bump();
        }
        yes
    }

    /// Skip whitespace and comments, collecting `///` docs. Returns (saw a line break, saw any
    /// whitespace or comment).
    fn skip_trivia(&mut self) -> Result<(bool, bool), Diag> {
        let (mut nl, mut space) = (false, false);
        loop {
            match self.peek() {
                Some('\n') => nl = true,
                Some(c) if c.is_whitespace() => {}
                Some('/') if self.peek_at(1) == Some('/') => {
                    let doc = self.peek_at(2) == Some('/') && self.peek_at(3) != Some('/');
                    let line = self.line;
                    let mut text = String::new();
                    while let Some(c) = self.peek().filter(|&c| c != '\n') {
                        text.push(c);
                        self.bump();
                    }
                    if doc {
                        if !self.docs.is_empty() && line != self.doc_line + 1 {
                            self.flush_docs();
                        }
                        let text = &text[3..];
                        self.docs.push(text.strip_prefix(' ').unwrap_or(text).trim_end().to_string());
                        self.doc_line = line;
                    }
                    space = true;
                    continue;
                }
                Some('/') if self.peek_at(1) == Some('*') => {
                    let start = self.here();
                    self.bump();
                    self.bump();
                    let mut depth = 1;
                    while depth > 0 {
                        match self.bump() {
                            None => {
                                return Err(Diag::new("E0003", self.from(start).to(start), "unterminated block comment")
                                    .note("`/*` comments nest; every `/*` needs its own `*/`"));
                            }
                            Some('\n') => nl = true,
                            Some('/') if self.eat('*') => depth += 1,
                            Some('*') if self.eat('/') => depth -= 1,
                            _ => {}
                        }
                    }
                    space = true;
                    continue;
                }
                _ => return Ok((nl, space)),
            }
            space = true;
            self.bump();
        }
    }

    /// A doc block that no token directly follows: the module doc if nothing came before it,
    /// otherwise dropped.
    fn flush_docs(&mut self) {
        let docs = std::mem::take(&mut self.docs);
        if !self.seen_token && self.module_doc.is_none() {
            self.module_doc = Some(docs.join("\n"));
        }
    }

    /// The next token and whether a line break preceded it. Inside the interpolation opened at
    /// `interp` in a one-line string, a line break or the end of the file means it was never
    /// closed.
    fn next_token(&mut self, interp: Option<Span>) -> Result<(Token, bool), Diag> {
        let (nl, space_before) = self.skip_trivia()?;
        if let Some(open) = interp
            && (nl || self.peek().is_none())
        {
            return Err(unclosed_interp(open));
        }
        let start = self.here();
        // A block directly above a token is that token's doc; at the end of the file there is
        // no item to own it, so it is the module doc (or dropped).
        let doc = if !self.docs.is_empty() && self.doc_line + 1 == start.line && self.peek().is_some() {
            Some(std::mem::take(&mut self.docs).join("\n"))
        } else {
            if !self.docs.is_empty() {
                self.flush_docs();
            }
            None
        };
        if space_before {
            self.unit_ok = false;
        }
        let tok = self.token(start)?;
        self.after_dot = matches!(tok, Tok::Dot | Tok::QuestionDot);
        self.unit_ok = matches!(&tok, Tok::Int(_) | Tok::Float(_)) || matches!(&tok, Tok::Ident(n) if n == "int" || n == "float");
        self.seen_token = true;
        Ok((Token { tok, span: self.from(start), doc, space_before }, nl))
    }

    fn token(&mut self, start: Span) -> Result<Tok, Diag> {
        let Some(c) = self.bump() else { return Ok(Tok::Eof) };
        let t = |lx: &mut Lexer, next: char, yes: Tok, no: Tok| if lx.eat(next) { yes } else { no };
        Ok(match c {
            '(' => Tok::LParen,
            ')' => Tok::RParen,
            '[' => Tok::LBracket,
            ']' => Tok::RBracket,
            '{' => Tok::LBrace,
            '}' => Tok::RBrace,
            ',' => Tok::Comma,
            ';' => {
                let span = self.from(start);
                return Err(Diag::new("E0011", span, "Duck does not use semicolons")
                    .note("a line break ends a statement; put the next statement on its own line")
                    .fix(span, ""));
            }
            ':' => t(self, ':', Tok::ColonColon, Tok::Colon),
            '.' if self.eat('.') => t(self, '=', Tok::DotDotEq, Tok::DotDot),
            '.' => Tok::Dot,
            '=' if self.eat('>') => Tok::FatArrow,
            '=' => t(self, '=', Tok::EqEq, Tok::Eq),
            '|' if self.eat('>') => Tok::PipeGt,
            '|' if self.eat('|') => Tok::OrOr,
            '|' => t(self, '=', Tok::PipeEq, Tok::Pipe),
            '^' => t(self, '=', Tok::CaretEq, Tok::Caret),
            '~' => Tok::Tilde,
            '?' if self.eat('.') => Tok::QuestionDot,
            '?' => t(self, '?', Tok::QuestionQuestion, Tok::Question),
            '!' => t(self, '=', Tok::BangEq, Tok::Bang),
            '&' if self.eat('&') => Tok::AndAnd,
            '&' => t(self, '=', Tok::AmpEq, Tok::Amp),
            '+' if self.eat('%') => Tok::PlusWrap,
            '+' => t(self, '=', Tok::PlusEq, Tok::Plus),
            '-' if self.eat('%') => Tok::MinusWrap,
            '-' if self.eat('>') => Tok::Arrow,
            '-' => t(self, '=', Tok::MinusEq, Tok::Minus),
            '*' if self.eat('*') => Tok::StarStar,
            '*' if self.eat('%') => Tok::StarWrap,
            '*' => t(self, '=', Tok::StarEq, Tok::Star),
            '/' => t(self, '=', Tok::SlashEq, Tok::Slash),
            '%' => t(self, '=', Tok::PercentEq, Tok::Percent),
            '<' if self.unit_ok && let Some(n) = self.unit_len() => {
                let text: String = (0..n).filter_map(|_| self.bump()).collect();
                self.bump();
                Tok::Unit(text.trim().to_string())
            }
            '<' if self.eat('<') => t(self, '=', Tok::ShlEq, Tok::Shl),
            '<' => t(self, '=', Tok::Le, Tok::Lt),
            '>' => t(self, '=', Tok::Ge, Tok::Gt),
            '"' => self.string(start, false)?,
            'r' if self.peek() == Some('"') => {
                self.bump();
                self.string(start, true)?
            }
            '\'' => self.char_lit(start)?,
            c if c.is_ascii_digit() => self.number(c, start)?,
            c if c.is_alphabetic() || c == '_' => {
                let mut s = String::from(c);
                while let Some(c) = self.peek().filter(|c| c.is_alphanumeric() || *c == '_') {
                    s.push(c);
                    self.bump();
                }
                keyword(&s).unwrap_or(Tok::Ident(s))
            }
            c => {
                let mut d = Diag::new("E0001", self.from(start), format!("unexpected character `{c}`"));
                d = match c {
                    '$' | '#' | '@' | '`' | '\\' => d.note("this character only appears inside strings and comments"),
                    _ => d,
                };
                return Err(d);
            }
        })
    }

    /// Just after a `<` that directly follows a number or `int`/`float`: the length of a unit
    /// before its closing `>`, if the rest of the line up to a `>` only has unit characters
    /// (names, digits, spaces, `* / ^ -`). Anything else (`3<x && y > 2`) is a comparison.
    fn unit_len(&self) -> Option<usize> {
        let mut i = 0;
        let mut name = false;
        loop {
            match self.peek_at(i)? {
                '>' => return name.then_some(i),
                c if c.is_alphanumeric() || c == '_' => name = true,
                ' ' | '*' | '/' | '^' | '-' => {}
                _ => return None,
            }
            i += 1;
        }
    }

    fn number(&mut self, first: char, start: Span) -> Result<Tok, Diag> {
        let radix = match (first, self.peek()) {
            ('0', Some('x' | 'X')) => 16,
            ('0', Some('b' | 'B')) => 2,
            _ => 10,
        };
        let mut s = String::new();
        if radix == 10 {
            s.push(first);
        } else {
            self.bump();
        }
        self.digits(&mut s, radix);
        let mut float = false;
        if radix == 10 && !self.after_dot {
            if self.peek() == Some('.') && self.peek_at(1).is_some_and(|c| c.is_ascii_digit()) {
                self.bump();
                s.push('.');
                self.digits(&mut s, 10);
                float = true;
            }
            let exp = match (self.peek(), self.peek_at(1), self.peek_at(2)) {
                (Some('e' | 'E'), Some(d), _) if d.is_ascii_digit() => true,
                (Some('e' | 'E'), Some('+' | '-'), Some(d)) => d.is_ascii_digit(),
                _ => false,
            };
            if exp {
                s.push(self.bump().unwrap());
                if let Some(sign @ ('+' | '-')) = self.peek() {
                    s.push(sign);
                    self.bump();
                }
                self.digits(&mut s, 10);
                float = true;
            }
        }
        if let Some(c) = self.peek().filter(|c| c.is_alphanumeric() || *c == '_') {
            let bad = self.here();
            let what = match radix {
                16 => "a hex",
                2 => "a binary",
                _ => "a number",
            };
            return Err(Diag::new("E0004", self.from(start).to(bad), format!("invalid character `{c}` in {what} literal"))
                .note("number literals look like `1_000`, `0xff`, `0b1010`, `3.14` or `1e-9`"));
        }
        if s.is_empty() {
            return Err(Diag::new("E0004", self.from(start), "expected digits after the radix prefix")
                .note("write e.g. `0xff` or `0b1010`"));
        }
        if float {
            return Ok(Tok::Float(s.parse().expect("valid float syntax")));
        }
        u64::from_str_radix(&s, radix).map(Tok::Int).map_err(|_| {
            Diag::new("E0005", self.from(start), "integer literal does not fit in 64 bits")
                .note("`int` is a 64-bit signed integer (at most 9_223_372_036_854_775_807)")
        })
    }

    /// Digits of `radix`, skipping `_` separators.
    fn digits(&mut self, s: &mut String, radix: u32) {
        while let Some(c) = self.peek() {
            if c.is_digit(radix) {
                s.push(c);
            } else if c != '_' {
                break;
            }
            self.bump();
        }
    }

    /// After a `\`: one escape sequence.
    fn escape(&mut self, start: Span) -> Result<char, Diag> {
        let bad = |lx: &Lexer, msg: String| {
            Diag::new("E0006", lx.from(start), msg)
                .note(r#"valid escapes are \n \t \r \0 \\ \" \' and \u{1F986}; a raw string r"..." has none"#)
        };
        Ok(match self.bump() {
            Some('n') => '\n',
            Some('t') => '\t',
            Some('r') => '\r',
            Some('0') => '\0',
            Some('\\') => '\\',
            Some('"') => '"',
            Some('\'') => '\'',
            Some('u') => {
                if !self.eat('{') {
                    return Err(bad(self, r"expected `{` after `\u` (write `\u{1F986}`)".into()));
                }
                let mut hex = String::new();
                while let Some(c) = self.peek().filter(|c| c.is_ascii_hexdigit()) {
                    hex.push(c);
                    self.bump();
                }
                if hex.is_empty() || hex.len() > 6 || !self.eat('}') {
                    return Err(bad(self, r"expected 1 to 6 hex digits and `}` in `\u{...}`".into()));
                }
                let n = u32::from_str_radix(&hex, 16).unwrap();
                char::from_u32(n).ok_or_else(|| bad(self, format!(r"`\u{{{hex}}}` is not a Unicode scalar value")))?
            }
            Some(c) if c != '\n' => return Err(bad(self, format!("unknown escape sequence `\\{c}`"))),
            _ => return Err(bad(self, "expected an escape sequence after `\\`".into())),
        })
    }

    fn char_lit(&mut self, start: Span) -> Result<Tok, Diag> {
        let c = match self.peek() {
            Some('\'') => {
                self.bump();
                return Err(Diag::new("E0007", self.from(start), "empty char literal").note("a char literal holds exactly one char, e.g. `'a'`"));
            }
            Some('\\') => {
                let at = self.here();
                self.bump();
                self.escape(at)?
            }
            Some(c) if c != '\n' => {
                self.bump();
                c
            }
            _ => return Err(Diag::new("E0007", self.from(start), "unterminated char literal").note("close it with `'`, e.g. `'a'`")),
        };
        if !self.eat('\'') {
            let mut d = Diag::new("E0007", self.from(start), "expected `'` to close the char literal");
            if (self.pos..self.chars.len()).map(|i| self.chars[i]).take_while(|&c| c != '\n').any(|c| c == '\'') {
                d = d.note("a char literal holds exactly one char; use double quotes for a string: \"...\"");
            }
            return Err(d);
        }
        Ok(Tok::Char(c))
    }

    /// After the opening `"` (or `r"`): a string literal. `"""` opens a triple-quoted string.
    fn string(&mut self, start: Span, raw: bool) -> Result<Tok, Diag> {
        let triple = self.peek() == Some('"') && self.peek_at(1) == Some('"');
        if triple {
            self.bump();
            self.bump();
        }
        let mut pieces = Vec::new();
        let mut lit = Vec::new();
        loop {
            let at = self.here();
            match self.peek() {
                None => {
                    return Err(Diag::new("E0002", self.from(start).to(start), "unterminated string literal")
                        .note(if triple { "close it with `\"\"\"`" } else { "close it with `\"`" }));
                }
                Some('\n') if !triple => {
                    return Err(Diag::new("E0002", self.from(start), "string literal is not closed on this line")
                        .note("write `\\n` for a line break, or use a triple-quoted string \"\"\"...\"\"\""));
                }
                Some('"') if !triple => {
                    self.bump();
                    break;
                }
                Some('"') if self.peek_at(1) == Some('"') && self.peek_at(2) == Some('"') => {
                    for _ in 0..3 {
                        self.bump();
                    }
                    break;
                }
                Some('\\') if !raw => {
                    self.bump();
                    lit.push((self.escape(at)?, true));
                }
                Some('{') if !raw && self.peek_at(1) == Some('{') => {
                    self.bump();
                    self.bump();
                    lit.push(('{', true));
                }
                Some('}') if !raw && self.peek_at(1) == Some('}') => {
                    self.bump();
                    self.bump();
                    lit.push(('}', true));
                }
                Some('{') if !raw => {
                    pieces.push(Piece::Lit(std::mem::take(&mut lit)));
                    pieces.push(Piece::Interp(self.interp(triple)?));
                }
                Some('}') if !raw => {
                    self.bump();
                    let span = self.from(at);
                    return Err(Diag::new("E0009", span, "unmatched `}` in a string")
                        .note("write `}}` for a literal `}` (and `{{` for `{`)")
                        .fix(span, "}}"));
                }
                Some(c) => {
                    self.bump();
                    lit.push((c, false));
                }
            }
        }
        pieces.push(Piece::Lit(lit));
        if triple {
            dedent(&mut pieces, self.from(start))?;
        }
        let mut parts: Vec<StrPart> = Vec::new();
        for p in pieces {
            match p {
                Piece::Lit(l) if l.is_empty() => {}
                Piece::Lit(l) => {
                    let s: String = l.into_iter().map(|(c, _)| c).collect();
                    match parts.last_mut() {
                        Some(StrPart::Lit(prev)) => prev.push_str(&s),
                        _ => parts.push(StrPart::Lit(s)),
                    }
                }
                Piece::Interp(i) => parts.push(i),
            }
        }
        Ok(Tok::Str(parts))
    }

    /// At the `{` of an interpolation: lex the expression up to the matching `}`, plus an
    /// optional format spec after a `:` at the top nesting level (`{x:.2}`, `{i + 1:>2}`).
    fn interp(&mut self, triple: bool) -> Result<StrPart, Diag> {
        let open = self.here();
        self.bump();
        let mut raw = Vec::new();
        let mut depth = 0usize;
        let mut spec = None;
        loop {
            let (tok, nl) = self.next_token(if triple { None } else { Some(open) })?;
            if tok.tok == Tok::Eof {
                return Err(unclosed_interp(open));
            }
            match tok.tok {
                Tok::LParen | Tok::LBracket | Tok::LBrace => depth += 1,
                Tok::RParen | Tok::RBracket => depth = depth.saturating_sub(1),
                Tok::RBrace if depth == 0 => break,
                Tok::RBrace => depth -= 1,
                Tok::Colon if depth == 0 => {
                    let mut s = String::new();
                    loop {
                        match self.bump() {
                            Some('}') => break,
                            Some(c) if c != '\n' && c != '"' => s.push(c),
                            _ => return Err(unclosed_interp(open)),
                        }
                    }
                    spec = Some(s);
                    break;
                }
                _ => {}
            }
            raw.push((tok, nl));
        }
        let span = self.from(open);
        if raw.is_empty() {
            return Err(Diag::new("E0008", span, "empty interpolation `{}` in a string")
                .note("put an expression inside, e.g. `{name}`, or write `{{}}` for literal braces")
                .fix(span, "{{}}"));
        }
        let end = Span { line: span.end_line, col: span.end_col - 1, ..span };
        raw.push((Token { tok: Tok::Eof, span: end, doc: None, space_before: false }, false));
        let toks = insert_newlines(raw, vec![('(', open)])?;
        self.after_dot = false;
        Ok(StrPart::Interp { toks, spec, span })
    }
}

fn unclosed_interp(open: Span) -> Diag {
    Diag::new("E0008", open, "unclosed `{` in string interpolation")
        .note("an interpolation is `{expr}` or `{expr:spec}`; write `{{` for a literal `{`")
}

/// Apply the triple-quoted string rules: drop the line break right after the opening quotes, and
/// strip the closing line's indentation (when the closing quotes start their own line) from
/// every line.
fn dedent(pieces: &mut [Piece], span: Span) -> Result<(), Diag> {
    let mut starts_with_newline = false;
    if let Some(Piece::Lit(l)) = pieces.first_mut() {
        let n = match l.as_slice() {
            [('\n', false), ..] => 1,
            [('\r', false), ('\n', false), ..] => 2,
            _ => 0,
        };
        l.drain(..n);
        starts_with_newline = n > 0;
    }
    let Some(Piece::Lit(last)) = pieces.last_mut() else { return Ok(()) };
    let Some(nl) = last.iter().rposition(|&(c, esc)| c == '\n' && !esc) else { return Ok(()) };
    if !last[nl + 1..].iter().all(|&(c, esc)| !esc && (c == ' ' || c == '\t')) {
        return Ok(());
    }
    let indent: Vec<char> = last.drain(nl + 1..).map(|(c, _)| c).collect();
    if indent.is_empty() {
        return Ok(());
    }
    let too_shallow = || {
        Diag::new("E0010", span, "a line in this triple-quoted string is indented less than its closing `\"\"\"`")
            .note(format!(
                "every line must start with the closing line's indentation ({} chars), which is removed",
                indent.len()
            ))
    };
    // The first line keeps its text when it shares a line with the opening quotes.
    let mut line_start = starts_with_newline;
    let n = pieces.len();
    for (i, piece) in pieces.iter_mut().enumerate() {
        match piece {
            Piece::Interp(_) if line_start => return Err(too_shallow()),
            Piece::Interp(_) => {}
            Piece::Lit(l) => {
                let mut out = Vec::with_capacity(l.len());
                let mut j = 0;
                while j < l.len() {
                    if line_start {
                        line_start = false;
                        let k = l[j..].iter().zip(&indent).take_while(|((c, esc), want)| !esc && c == *want).count();
                        let blank = match l.get(j + k) {
                            Some(&(c, esc)) => c == '\n' && !esc || c == '\r' && !esc,
                            None => i + 1 == n,
                        };
                        if k < indent.len() && !blank {
                            return Err(too_shallow());
                        }
                        j += k;
                        continue;
                    }
                    let (c, esc) = l[j];
                    out.push((c, esc));
                    line_start = c == '\n' && !esc;
                    j += 1;
                }
                *l = out;
            }
        }
    }
    Ok(())
}

/// A line break here can't end a statement because the line ends with this token.
fn continues_after(t: &Tok) -> bool {
    use Tok::*;
    matches!(
        t,
        Plus | Minus
            | Star
            | Slash
            | Percent
            | StarStar
            | PlusWrap
            | MinusWrap
            | StarWrap
            | EqEq
            | BangEq
            | Lt
            | Le
            | Gt
            | Ge
            | AndAnd
            | OrOr
            | DotDot
            | DotDotEq
            | PipeGt
            | Eq
            | PlusEq
            | MinusEq
            | StarEq
            | SlashEq
            | PercentEq
            | Pipe
            | Caret
            | Tilde
            | Shl
            | AmpEq
            | PipeEq
            | CaretEq
            | ShlEq
            | FatArrow
            | Arrow
            | Comma
            | Colon
            | ColonColon
            | Dot
            | QuestionDot
            | Amp
            | LParen
            | LBracket
            | LBrace
            // keyword operators that need a right-hand side
            | Is
            | In
            | Else
            | When
            | Uses
            | Requires
            | Ensures
            | Await
    )
}

/// A line break here can't end a statement because the next line starts with this token.
fn continues_before(t: &Tok) -> bool {
    matches!(t, Tok::Dot | Tok::PipeGt | Tok::Requires | Tok::Ensures | Tok::LBrace)
}

/// Turn raw tokens (each flagged with "a line break came before it") into the final stream:
/// insert `Newline` where a statement can end, and check that brackets match.
///
/// A line break is significant only directly inside braces (a block is a statement list) or at
/// the top level; inside `(...)` and `[...]` it is always insignificant. Even there, the line
/// continues when it ends with an operator, `=`, `=>`, `,` or an open bracket, or when the next
/// line starts with `.`, `|>`, `requires`, `ensures` or `{`. `stack` holds the brackets already
/// open (an interpolation starts inside a virtual `(`).
fn insert_newlines(raw: Vec<(Token, bool)>, mut stack: Vec<(char, Span)>) -> Result<Vec<Token>, Diag> {
    let base = stack.len();
    let mut out: Vec<Token> = Vec::with_capacity(raw.len() + raw.len() / 4);
    for (tok, nl) in raw {
        if nl
            && tok.tok != Tok::Eof
            && matches!(stack.last(), None | Some(('{', _)))
            && let Some(prev) = out.last()
            && !continues_after(&prev.tok)
            && !continues_before(&tok.tok)
        {
            let span = prev.span.after();
            out.push(Token { tok: Tok::Newline, span, doc: None, space_before: false });
        }
        let open = match tok.tok {
            Tok::LParen => Some('('),
            Tok::LBracket => Some('['),
            Tok::LBrace => Some('{'),
            _ => None,
        };
        let close = match tok.tok {
            Tok::RParen => Some(('(', ')')),
            Tok::RBracket => Some(('[', ']')),
            Tok::RBrace => Some(('{', '}')),
            _ => None,
        };
        if let Some(o) = open {
            stack.push((o, tok.span));
        } else if let Some((want, c)) = close {
            match stack.last() {
                Some(&(o, at)) if stack.len() > base && o != want => {
                    return Err(Diag::new("E0013", tok.span, format!("expected `{}` to close the `{o}` at {at}, found `{c}`", closer(o)))
                        .note(format!("the `{o}` opened at {at} is still open")));
                }
                Some(_) if stack.len() > base => {
                    stack.pop();
                }
                _ => return Err(Diag::new("E0013", tok.span, format!("unmatched `{c}`")).note(format!("there is no open `{want}` for it to close"))),
            }
        } else if tok.tok == Tok::Eof && stack.len() > base {
            let (o, at) = stack[stack.len() - 1];
            return Err(Diag::new("E0012", at, format!("unclosed `{o}`"))
                .note(format!("expected a `{}` to close it before {}", closer(o), if base == 0 { "the end of the file" } else { "the end of the interpolation" })));
        }
        out.push(tok);
    }
    Ok(out)
}

fn closer(open: char) -> char {
    match open {
        '(' => ')',
        '[' => ']',
        _ => '}',
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(src: &str) -> Vec<Tok> {
        lex(src).unwrap_or_else(|d| panic!("{}", d.render("t", src))).toks.into_iter().map(|t| t.tok).collect()
    }

    /// Token kinds as compact text, with `;` for significant newlines.
    fn shape(src: &str) -> String {
        toks(src)
            .iter()
            .map(|t| match t {
                Tok::Ident(s) => s.clone(),
                Tok::Int(n) => n.to_string(),
                Tok::Float(x) => format!("{x:?}"),
                Tok::Char(c) => format!("{c:?}"),
                Tok::Str(_) => "STR".into(),
                Tok::Newline => ";".into(),
                Tok::Eof => "EOF".into(),
                t => t.text().into(),
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn err(src: &str) -> Diag {
        lex(src).expect_err("expected a lex error")
    }

    fn str_parts(src: &str) -> Vec<StrPart> {
        match toks(src).into_iter().next() {
            Some(Tok::Str(p)) => p,
            t => panic!("not a string: {t:?}"),
        }
    }

    fn lit(src: &str) -> String {
        match str_parts(src).as_slice() {
            [] => String::new(),
            [StrPart::Lit(s)] => s.clone(),
            p => panic!("not a plain string: {p:?}"),
        }
    }

    #[test]
    fn newline_ends_statements() {
        assert_eq!(shape("let a = 1\nlet b = 2"), "let a = 1 ; let b = 2 EOF");
        assert_eq!(shape("\n\nf()\n\n\ng()\n"), "f ( ) ; g ( ) EOF");
        // in a block too
        assert_eq!(shape("{\n  a\n  b\n}"), "{ a ; b ; } EOF");
    }

    #[test]
    fn newline_continues_after_operators() {
        assert_eq!(shape("a +\n b"), "a + b EOF");
        assert_eq!(shape("a ==\n b"), "a == b EOF");
        assert_eq!(shape("let x =\n 1"), "let x = 1 EOF");
        assert_eq!(shape("x =>\n y"), "x => y EOF");
        assert_eq!(shape("f(a,\n b)"), "f ( a , b ) EOF");
        assert_eq!(shape("[\n 1\n]"), "[ 1 ] EOF");
        assert_eq!(shape("a else\n b"), "a else b EOF");
        // postfix `?` and `!` can end a line
        assert_eq!(shape("a?\nb!\nc"), "a ? ; b ! ; c EOF");
    }

    #[test]
    fn newline_continues_before_leading_tokens() {
        assert_eq!(shape("app()\n  .switch()\n  .arg()"), "app ( ) . switch ( ) . arg ( ) EOF");
        assert_eq!(shape("rows\n  |> f()\n  |> g()?"), "rows |> f ( ) |> g ( ) ? EOF");
        assert_eq!(
            shape("fn f(n: int): int\n  requires n > 0\n  ensures result > 0\n{ ?? }"),
            "fn f ( n : int ) : int requires n > 0 ensures result > 0 { ?? } EOF"
        );
        // a `..` line is not a `.` line
        assert_eq!(shape("a\n..b"), "a ; .. b EOF");
    }

    #[test]
    fn newlines_inside_brackets() {
        // insignificant directly inside parens and brackets, even without a trailing operator
        assert_eq!(shape("f(\n a\n b\n)"), "f ( a b ) EOF");
        assert_eq!(shape("[a\n b]"), "[ a b ] EOF");
        // significant again inside braces nested in parens
        assert_eq!(shape("f(x => {\n a\n b\n})"), "f ( x => { a ; b ; } ) EOF");
        // `} else` across a line break inside parens: no newline
        assert_eq!(shape("(if a { b }\n else { c })"), "( if a { b } else { c } ) EOF");
    }

    #[test]
    fn comments_and_docs() {
        assert_eq!(shape("a // x\n/* y /* nested */ z */ b"), "a ; b EOF");
        assert_eq!(shape("a /* spans\nlines */ b"), "a ; b EOF");
        let lx = lex("/// module\n\n/// one\n/// two\nfn f() {}\n").unwrap();
        assert_eq!(lx.module_doc.as_deref(), Some("module"));
        assert_eq!(lx.toks[0].doc.as_deref(), Some("one\ntwo"));
        // a doc separated from the item by a blank line is not the item's doc
        let lx = lex("fn g() {}\n/// stray\n\nfn f() {}").unwrap();
        assert!(lx.toks.iter().all(|t| t.doc.is_none()));
        // a block at the end of the file has no item to belong to: it is the module doc
        let lx = lex("/// module\n").unwrap();
        assert_eq!(lx.module_doc.as_deref(), Some("module"));
        assert!(lx.toks.iter().all(|t| t.doc.is_none()));
        // `////` is an ordinary comment
        assert!(lex("//// x\nfn f() {}").unwrap().toks[0].doc.is_none());
        assert_eq!(err("a /* x /* y */").code, "E0003");
    }

    #[test]
    fn numbers() {
        assert_eq!(toks("1_000 0xff 0b1010 1e-9 3.25 2.5E+3 0xD800")[..7], [
            Tok::Int(1000),
            Tok::Int(255),
            Tok::Int(10),
            Tok::Float(1e-9),
            Tok::Float(3.25),
            Tok::Float(2500.0),
            Tok::Int(0xD800)
        ]);
        assert_eq!(shape("0..3"), "0 .. 3 EOF");
        assert_eq!(shape("1.max()"), "1 . max ( ) EOF");
        assert_eq!(shape("t.0.1"), "t . 0 . 1 EOF");
        assert_eq!(shape("x?.0"), "x ?. 0 EOF");
    }

    #[test]
    fn bad_numbers() {
        let d = err("let x = 12abc");
        assert_eq!(d.code, "E0004");
        assert!(d.message.contains("invalid character `a` in a number literal"));
        assert_eq!(err("0x").code, "E0004");
        let d = err("99999999999999999999");
        assert_eq!((d.code, d.message.as_str()), ("E0005", "integer literal does not fit in 64 bits"));
    }

    #[test]
    fn chars() {
        assert_eq!(toks(r"'a' '\n' '\u{1F986}' '\'' '{'")[..5], [
            Tok::Char('a'),
            Tok::Char('\n'),
            Tok::Char('🦆'),
            Tok::Char('\''),
            Tok::Char('{')
        ]);
        assert_eq!(err("''").code, "E0007");
        let d = err("'ab'");
        assert_eq!(d.code, "E0007");
        assert!(d.notes[0].contains("double quotes"));
        assert_eq!(err(r"'\q'").code, "E0006");
    }

    #[test]
    fn string_escapes_and_braces() {
        assert_eq!(lit(r#""a\tb\n\"q\" \\ \0 \u{41}""#), "a\tb\n\"q\" \\ \0 A");
        assert_eq!(lit(r#""{{x}} }}""#), "{x} }");
        assert_eq!(lit(r#""$""#), "$");
        let d = err(r#""\q""#);
        assert_eq!(d.code, "E0006");
        assert_eq!(d.message, "unknown escape sequence `\\q`");
        assert_eq!(err(r#""\u{110000}""#).code, "E0006");
        let d = err("\"abc\nd\"");
        assert_eq!((d.code, d.message.as_str()), ("E0002", "string literal is not closed on this line"));
        assert_eq!(err("\"abc").code, "E0002");
        let d = err(r#""a } b""#);
        assert_eq!(d.code, "E0009");
        assert_eq!(d.fixes[0].text, "}}");
    }

    fn interp(p: &StrPart) -> (String, Option<String>) {
        let StrPart::Interp { toks, spec, .. } = p else { panic!("not an interpolation: {p:?}") };
        let s = toks
            .iter()
            .map(|t| match &t.tok {
                Tok::Ident(s) => s.clone(),
                Tok::Int(n) => n.to_string(),
                Tok::Str(_) => "STR".into(),
                t => t.text().into(),
            })
            .collect::<Vec<_>>()
            .join(" ");
        (s, spec.clone())
    }

    #[test]
    fn interpolation() {
        let p = str_parts(r#""hi {name}, {x:.2} {n:>5} {i + 1:>2} {v:02}!""#);
        assert_eq!(p.len(), 11);
        assert_eq!(p[0], StrPart::Lit("hi ".into()));
        assert_eq!(interp(&p[1]), ("name end of file".into(), None));
        assert_eq!(interp(&p[3]), ("x end of file".into(), Some(".2".into())));
        assert_eq!(interp(&p[5]), ("n end of file".into(), Some(">5".into())));
        assert_eq!(interp(&p[7]), ("i + 1 end of file".into(), Some(">2".into())));
        assert_eq!(interp(&p[9]).1.as_deref(), Some("02"));
        assert_eq!(p[10], StrPart::Lit("!".into()));
    }

    #[test]
    fn interpolation_nesting() {
        // strings and braces nest inside an interpolation
        let p = str_parts(r#""{if a { "x" } else { "y" }}""#);
        assert_eq!(interp(&p[0]), ("if a { STR } else { STR } end of file".into(), None));
        // a `:` inside nested brackets is not a format spec
        let p = str_parts(r#""{f({"k": 1})}""#);
        assert_eq!(interp(&p[0]).1, None);
        // a nested string with its own interpolation and spec
        let p = str_parts(r#""a{"b{c:>3}d":<9}e""#);
        assert_eq!(interp(&p[1]).1.as_deref(), Some("<9"));
        let StrPart::Interp { toks, .. } = &p[1] else { panic!() };
        let Tok::Str(inner) = &toks[0].tok else { panic!() };
        assert_eq!(interp(&inner[1]), ("c end of file".into(), Some(">3".into())));
        // escapes next to interpolations
        let p = str_parts(r#""\\{c}""#);
        assert_eq!(p[0], StrPart::Lit("\\".into()));
        assert_eq!(interp(&p[1]).0, "c end of file");
        // empty and unclosed interpolations
        assert_eq!(err(r#""{}""#).code, "E0008");
        let d = err("\"{x\n\"");
        assert_eq!((d.code, d.message.as_str()), ("E0008", "unclosed `{` in string interpolation"));
    }

    #[test]
    fn raw_strings() {
        assert_eq!(lit(r#"r"a\n{b}""#), r"a\n{b}");
        assert_eq!(lit(r#"r"]}""#), "]}");
        assert_eq!(lit(r#"r"""{"name":"ann"}""""#), r#"{"name":"ann"}"#);
        // `r` alone is still an identifier
        assert_eq!(shape("r + 1"), "r + 1 EOF");
    }

    #[test]
    fn triple_strings_dedent() {
        let src = "\"\"\"\n    .....\n    ..#..\n    \"\"\"";
        assert_eq!(lit(src), ".....\n..#..\n");
        // relative indentation is kept; blank lines are fine
        assert_eq!(lit("r\"\"\"\n    {\n      \"a\": 1\n\n    }\n  \"\"\""), "  {\n    \"a\": 1\n\n  }\n");
        // closing quotes after text: nothing to strip
        assert_eq!(lit("r\"\"\"{\n  \"a\": tru\n}\"\"\""), "{\n  \"a\": tru\n}");
        // interpolation in a triple string
        let p = str_parts("\"\"\"\n  x = {x}\n  \"\"\"");
        assert_eq!(p[0], StrPart::Lit("x = ".into()));
        assert_eq!(p[2], StrPart::Lit("\n".into()));
        // an escaped newline is not a line start
        assert_eq!(lit("\"\"\"\n  a\\n  b\n  \"\"\""), "a\n  b\n");
        // a line indented less than the closing quotes
        let d = err("\"\"\"\n    a\n  b\n    \"\"\"");
        assert_eq!(d.code, "E0010");
    }

    #[test]
    fn operators() {
        assert_eq!(
            shape("+% -% *% ** .. ..= => |> ?. ? ?? :: & ! != += -= *= /= %= && || -> < <= > >="),
            "+% -% *% ** .. ..= => |> ?. ? ?? :: & ! != += -= *= /= %= && || -> < <= > >= EOF"
        );
        assert_eq!(shape("xs.max()!"), "xs . max ( ) ! EOF");
    }

    #[test]
    fn keywords_and_contextual_words() {
        assert_eq!(
            toks("fn test shape imprint peek any when uses")[..8],
            [
                Tok::Fn,
                Tok::Ident("test".into()),
                Tok::Ident("shape".into()),
                Tok::Ident("imprint".into()),
                Tok::Ident("peek".into()),
                Tok::Ident("any".into()),
                Tok::When,
                Tok::Uses
            ]
        );
    }

    #[test]
    fn brackets_must_match() {
        let d = err("f(a]");
        assert_eq!(d.code, "E0013");
        assert_eq!(d.message, "expected `)` to close the `(` at 1:2, found `]`");
        let d = err("fn f() {\n  g(\n}");
        assert_eq!(d.code, "E0013");
        let d = err("fn f() {\n  g()\n");
        assert_eq!((d.code, d.span.line, d.span.col), ("E0012", 1, 8));
        assert_eq!(err(")").message, "unmatched `)`");
    }

    #[test]
    fn semicolons_and_stray_chars() {
        let d = err("let x = 1;");
        assert_eq!((d.code, d.span.col), ("E0011", 10));
        assert_eq!(d.fixes[0].text, "");
        let d = err("a $ b");
        assert_eq!(d.code, "E0001");
        assert!(d.notes[0].contains("strings and comments"));
    }

    #[test]
    fn bitwise_operators() {
        assert_eq!(shape("a & b | c ^ ~d << 2 >> 1"), "a & b | c ^ ~ d << 2 > > 1 EOF");
        assert_eq!(shape("a &= b |= c ^= d <<= e >>= f && g || h |> i"), "a &= b |= c ^= d <<= e > >= f && g || h |> i EOF");
        // `^` inside a unit is part of the unit; `<<` after a number is not a unit
        assert_eq!(toks("3.0<m/s^2> 1<<4")[1], Tok::Unit("m/s^2".into()));
        assert_eq!(shape("1<<4"), "1 << 4 EOF");
        // a line ending in a bitwise operator continues
        assert_eq!(shape("a &\nb |\nc ^\nd <<\ne"), "a & b | c ^ d << e EOF");
    }

    #[test]
    fn spans_cover_tokens() {
        let lx = lex("let abc = \"x{y}z\"\n  1.5").unwrap();
        let s = lx.toks[1].span;
        assert_eq!((s.line, s.col, s.end_line, s.end_col), (1, 5, 1, 8));
        let s = lx.toks[3].span;
        assert_eq!((s.col, s.end_col), (11, 18));
        let s = lx.toks[5].span;
        assert_eq!((s.line, s.col, s.end_col), (2, 3, 6));
        let Tok::Str(p) = &lx.toks[3].tok else { panic!() };
        let StrPart::Interp { toks, span, .. } = &p[1] else { panic!() };
        assert_eq!((span.col, span.end_col), (13, 16));
        assert_eq!((toks[0].span.col, toks[0].span.end_col), (14, 15));
    }
}
