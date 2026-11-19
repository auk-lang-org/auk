/// Tokens produced by the lexer (src/token.rs).

pub enum Tok {
  /// Unsigned 64-bit: the bits are kept in an `int` (Auk has no u64), so a literal above
  /// 2^63 - 1 reads as negative; `uint_str` prints it unsigned.
  Int(n: int),
  Float(x: float),
  Char(c: char),
  /// A string literal of any kind, already unescaped and dedented, split into literal text
  /// and interpolations.
  Str(parts: [StrPart]),
  /// Identifiers, including contextual keywords and `_`.
  Ident(s: str),
  /// `<m/s>` directly after a number literal or `int`/`float`.
  Unit(s: str),
  // keywords
  Fn,
  Let,
  Var,
  If,
  Else,
  Match,
  Loop,
  While,
  For,
  In,
  Break,
  Continue,
  Return,
  True,
  False,
  Struct,
  Enum,
  Pub,
  Async,
  Await,
  Catch,
  Is,
  When,
  Uses,
  Requires,
  Ensures,
  Assert,
  // brackets and punctuation
  LParen,
  RParen,
  LBracket,
  RBracket,
  LBrace,
  RBrace,
  Comma,
  Colon,
  ColonColon,
  Dot,
  DotDot,
  DotDotEq,
  FatArrow,
  Arrow,
  PipeGt,
  Question,
  QuestionDot,
  QuestionQuestion,
  Bang,
  Amp,
  Eq,
  // operators
  Plus,
  Minus,
  Star,
  Slash,
  Percent,
  StarStar,
  PlusWrap,
  MinusWrap,
  StarWrap,
  EqEq,
  BangEq,
  Lt,
  Le,
  Gt,
  Ge,
  AndAnd,
  OrOr,
  PlusEq,
  MinusEq,
  StarEq,
  SlashEq,
  PercentEq,
  // bitwise
  Pipe,
  Caret,
  Tilde,
  Shl,
  AmpEq,
  PipeEq,
  CaretEq,
  ShlEq,
  /// A significant line break.
  Newline,
  Eof,
  /// `;`, only in an array type `[T; N]` (the runtime's dialect); elsewhere E0011.
  Semi,
}

/// A piece of a string literal. `toks` ends with `Eof`; `spec` is the raw text after the
/// top-level `:`; `span` covers the braces.
pub enum StrPart {
  Lit(s: str),
  Interp(toks: [Token], spec: str?, span: diag.Span),
}

pub struct Token {
  tok: Tok,
  span: diag.Span,
  /// The `///` doc comment lines directly above this token, joined with `\n`.
  doc: str?,
  /// Whitespace or a comment separates this token from the previous one.
  space_before: bool,
}

/// The keyword spelled `s`, if any.
pub fn keyword(s: str): Tok? = match s {
  "fn" => Fn
  "let" => Let
  "var" => Var
  "if" => If
  "else" => Else
  "match" => Match
  "loop" => Loop
  "while" => While
  "for" => For
  "in" => In
  "break" => Break
  "continue" => Continue
  "return" => Return
  "true" => True
  "false" => False
  "struct" => Struct
  "enum" => Enum
  "pub" => Pub
  "async" => Async
  "await" => Await
  "catch" => Catch
  "is" => Is
  "when" => When
  "uses" => Uses
  "requires" => Requires
  "ensures" => Ensures
  "assert" => Assert
  _ => none
}

/// Is `t` a keyword token?
pub fn is_keyword(t: Tok): bool = match t {
  Fn => true
  Let => true
  Var => true
  If => true
  Else => true
  Match => true
  Loop => true
  While => true
  For => true
  In => true
  Break => true
  Continue => true
  Return => true
  True => true
  False => true
  Struct => true
  Enum => true
  Pub => true
  Async => true
  Await => true
  Catch => true
  Is => true
  When => true
  Uses => true
  Requires => true
  Ensures => true
  Assert => true
  _ => false
}

/// The source spelling of a fixed token ("" for literals and names).
pub fn text(t: Tok): str = match t {
  Fn => "fn"
  Let => "let"
  Var => "var"
  If => "if"
  Else => "else"
  Match => "match"
  Loop => "loop"
  While => "while"
  For => "for"
  In => "in"
  Break => "break"
  Continue => "continue"
  Return => "return"
  True => "true"
  False => "false"
  Struct => "struct"
  Enum => "enum"
  Pub => "pub"
  Async => "async"
  Await => "await"
  Catch => "catch"
  Is => "is"
  When => "when"
  Uses => "uses"
  Requires => "requires"
  Ensures => "ensures"
  Assert => "assert"
  LParen => "("
  RParen => ")"
  LBracket => "["
  RBracket => "]"
  LBrace => "{{"
  RBrace => "}}"
  Comma => ","
  Colon => ":"
  ColonColon => "::"
  Dot => "."
  DotDot => ".."
  DotDotEq => "..="
  FatArrow => "=>"
  Arrow => "->"
  PipeGt => "|>"
  Question => "?"
  QuestionDot => "?."
  QuestionQuestion => "??"
  Bang => "!"
  Amp => "&"
  Eq => "="
  Plus => "+"
  Minus => "-"
  Star => "*"
  Slash => "/"
  Percent => "%"
  StarStar => "**"
  PlusWrap => "+%"
  MinusWrap => "-%"
  StarWrap => "*%"
  EqEq => "=="
  BangEq => "!="
  Lt => "<"
  Le => "<="
  Gt => ">"
  Ge => ">="
  AndAnd => "&&"
  OrOr => "||"
  PlusEq => "+="
  MinusEq => "-="
  StarEq => "*="
  SlashEq => "/="
  PercentEq => "%="
  Pipe => "|"
  Caret => "^"
  Tilde => "~"
  Shl => "<<"
  AmpEq => "&="
  PipeEq => "|="
  CaretEq => "^="
  ShlEq => "<<="
  Semi => ";"
  Newline => "newline"
  Eof => "end of file"
  _ => ""
}

/// The variant name, as `{t:?}` prints a payload-less token in Rust.
pub fn name(t: Tok): str = match t {
  Int(_) => "Int"
  Float(_) => "Float"
  Char(_) => "Char"
  Str(_) => "Str"
  Ident(_) => "Ident"
  Unit(_) => "Unit"
  Fn => "Fn"
  Let => "Let"
  Var => "Var"
  If => "If"
  Else => "Else"
  Match => "Match"
  Loop => "Loop"
  While => "While"
  For => "For"
  In => "In"
  Break => "Break"
  Continue => "Continue"
  Return => "Return"
  True => "True"
  False => "False"
  Struct => "Struct"
  Enum => "Enum"
  Pub => "Pub"
  Async => "Async"
  Await => "Await"
  Catch => "Catch"
  Is => "Is"
  When => "When"
  Uses => "Uses"
  Requires => "Requires"
  Ensures => "Ensures"
  Assert => "Assert"
  LParen => "LParen"
  RParen => "RParen"
  LBracket => "LBracket"
  RBracket => "RBracket"
  LBrace => "LBrace"
  RBrace => "RBrace"
  Comma => "Comma"
  Colon => "Colon"
  ColonColon => "ColonColon"
  Dot => "Dot"
  DotDot => "DotDot"
  DotDotEq => "DotDotEq"
  FatArrow => "FatArrow"
  Arrow => "Arrow"
  PipeGt => "PipeGt"
  Question => "Question"
  QuestionDot => "QuestionDot"
  QuestionQuestion => "QuestionQuestion"
  Bang => "Bang"
  Amp => "Amp"
  Eq => "Eq"
  Plus => "Plus"
  Minus => "Minus"
  Star => "Star"
  Slash => "Slash"
  Percent => "Percent"
  StarStar => "StarStar"
  PlusWrap => "PlusWrap"
  MinusWrap => "MinusWrap"
  StarWrap => "StarWrap"
  EqEq => "EqEq"
  BangEq => "BangEq"
  Lt => "Lt"
  Le => "Le"
  Gt => "Gt"
  Ge => "Ge"
  AndAnd => "AndAnd"
  OrOr => "OrOr"
  PlusEq => "PlusEq"
  MinusEq => "MinusEq"
  StarEq => "StarEq"
  SlashEq => "SlashEq"
  PercentEq => "PercentEq"
  Pipe => "Pipe"
  Caret => "Caret"
  Tilde => "Tilde"
  Shl => "Shl"
  AmpEq => "AmpEq"
  PipeEq => "PipeEq"
  CaretEq => "CaretEq"
  ShlEq => "ShlEq"
  Newline => "Newline"
  Eof => "Eof"
  Semi => "Semi"
}

/// How a token reads in "expected X, found Y" (Rust's `Display for Tok`).
pub fn display(t: Tok): str = match t {
  Int(n) => "`{uint_str(n)}`"
  Float(x) => "`{float_debug(x)}`"
  Char(c) => "`{char_debug(c)}`"
  Str(_) => "a string"
  Ident(s) => "`{s}`"
  Unit(s) => "the unit `<{s}>`"
  Newline => "a line break"
  Eof => "the end of the file"
  _ => "`{t.text()}`"
}

/// The int's bits read as an unsigned 64-bit number.
pub fn uint_str(n: int): str {
  if n >= 0 { return "{n}" }
  let q = ((n >> 1) & 0x7fffffffffffffff) / 5
  let r = n -% q *% 10
  "{q}{r}"
}

/// Rust's `{:?}` of an f64 (always has a `.` or an exponent).
pub fn float_debug(x: float): str {
  let s = "{x}"
  if s.contains(".") || s.contains("e") || s.contains("inf") || s.contains("NaN") {
    s
  } else {
    s + ".0"
  }
}

/// Rust's `{:?}` of a char (approximately: the common escapes).
pub fn char_debug(c: char): str = match c {
  '\n' => "'\\n'"
  '\t' => "'\\t'"
  '\r' => "'\\r'"
  '\0' => "'\\0'"
  '\'' => "'\\''"
  '\\' => "'\\\\'"
  _ => "'{c}'"
}
