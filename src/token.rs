//! Tokens produced by the lexer.

use std::fmt;

use super::diag::Span;

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    /// Unsigned; a leading `-` is a separate token. Range-checked by the type checker.
    Int(u64),
    Float(f64),
    Char(char),
    /// A string literal of any kind (`"..."`, `r"..."`, `"""..."""`), already unescaped and
    /// dedented, split into literal text and interpolations.
    Str(Vec<StrPart>),
    /// Identifiers, including contextual keywords (`test`, `shape`, `imprint`, `peek`, `any`)
    /// and `_`.
    Ident(String),
    /// `<m/s>` written directly after a number literal or after `int`/`float` (no space before
    /// the `<`): a unit of measure, as written between the brackets.
    Unit(String),
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
    /// `->`: not Duck syntax; lexed only so the parser can suggest `:`.
    Arrow,
    PipeGt,
    Question,
    QuestionDot,
    /// `??`: a hole, or two postfix `?` in a row.
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
    // bitwise (`>>` and `>>=` are two adjacent `>` / `>` `>=` tokens, joined by the parser so
    // nested generics `Set<Set<int>>` still close)
    Pipe,
    Caret,
    Tilde,
    Shl,
    AmpEq,
    PipeEq,
    CaretEq,
    ShlEq,
    /// A significant line break: one that can end a statement (see `lexer::insert_newlines`).
    Newline,
    Eof,
}

/// A piece of a string literal.
#[derive(Debug, Clone, PartialEq)]
pub enum StrPart {
    Lit(String),
    /// `{expr}` or `{expr:spec}`. `toks` ends with `Eof`; `spec` is the raw text after the
    /// top-level `:`; `span` covers the braces.
    Interp { toks: Vec<Token>, spec: Option<String>, span: Span },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Token {
    pub tok: Tok,
    pub span: Span,
    /// The `///` doc comment lines directly above this token, joined with `\n`.
    pub doc: Option<String>,
    /// Whitespace or a comment separates this token from the previous one.
    pub space_before: bool,
}

/// The keyword spelled `s`, if any.
pub fn keyword(s: &str) -> Option<Tok> {
    Some(match s {
        "fn" => Tok::Fn,
        "let" => Tok::Let,
        "var" => Tok::Var,
        "if" => Tok::If,
        "else" => Tok::Else,
        "match" => Tok::Match,
        "loop" => Tok::Loop,
        "while" => Tok::While,
        "for" => Tok::For,
        "in" => Tok::In,
        "break" => Tok::Break,
        "continue" => Tok::Continue,
        "return" => Tok::Return,
        "true" => Tok::True,
        "false" => Tok::False,
        "struct" => Tok::Struct,
        "enum" => Tok::Enum,
        "pub" => Tok::Pub,
        "async" => Tok::Async,
        "await" => Tok::Await,
        "is" => Tok::Is,
        "when" => Tok::When,
        "uses" => Tok::Uses,
        "requires" => Tok::Requires,
        "ensures" => Tok::Ensures,
        "assert" => Tok::Assert,
        _ => return None,
    })
}

impl Tok {
    /// The source spelling of a fixed token.
    pub fn text(&self) -> &'static str {
        match self {
            Tok::Int(_) | Tok::Float(_) | Tok::Char(_) | Tok::Str(_) | Tok::Ident(_) | Tok::Unit(_) => "",
            Tok::Fn => "fn",
            Tok::Let => "let",
            Tok::Var => "var",
            Tok::If => "if",
            Tok::Else => "else",
            Tok::Match => "match",
            Tok::Loop => "loop",
            Tok::While => "while",
            Tok::For => "for",
            Tok::In => "in",
            Tok::Break => "break",
            Tok::Continue => "continue",
            Tok::Return => "return",
            Tok::True => "true",
            Tok::False => "false",
            Tok::Struct => "struct",
            Tok::Enum => "enum",
            Tok::Pub => "pub",
            Tok::Async => "async",
            Tok::Await => "await",
            Tok::Is => "is",
            Tok::When => "when",
            Tok::Uses => "uses",
            Tok::Requires => "requires",
            Tok::Ensures => "ensures",
            Tok::Assert => "assert",
            Tok::LParen => "(",
            Tok::RParen => ")",
            Tok::LBracket => "[",
            Tok::RBracket => "]",
            Tok::LBrace => "{",
            Tok::RBrace => "}",
            Tok::Comma => ",",
            Tok::Colon => ":",
            Tok::ColonColon => "::",
            Tok::Dot => ".",
            Tok::DotDot => "..",
            Tok::DotDotEq => "..=",
            Tok::FatArrow => "=>",
            Tok::Arrow => "->",
            Tok::PipeGt => "|>",
            Tok::Question => "?",
            Tok::QuestionDot => "?.",
            Tok::QuestionQuestion => "??",
            Tok::Bang => "!",
            Tok::Amp => "&",
            Tok::Eq => "=",
            Tok::Plus => "+",
            Tok::Minus => "-",
            Tok::Star => "*",
            Tok::Slash => "/",
            Tok::Percent => "%",
            Tok::StarStar => "**",
            Tok::PlusWrap => "+%",
            Tok::MinusWrap => "-%",
            Tok::StarWrap => "*%",
            Tok::EqEq => "==",
            Tok::BangEq => "!=",
            Tok::Lt => "<",
            Tok::Le => "<=",
            Tok::Gt => ">",
            Tok::Ge => ">=",
            Tok::AndAnd => "&&",
            Tok::OrOr => "||",
            Tok::PlusEq => "+=",
            Tok::MinusEq => "-=",
            Tok::StarEq => "*=",
            Tok::SlashEq => "/=",
            Tok::PercentEq => "%=",
            Tok::Pipe => "|",
            Tok::Caret => "^",
            Tok::Tilde => "~",
            Tok::Shl => "<<",
            Tok::AmpEq => "&=",
            Tok::PipeEq => "|=",
            Tok::CaretEq => "^=",
            Tok::ShlEq => "<<=",
            Tok::Newline => "newline",
            Tok::Eof => "end of file",
        }
    }
}

impl fmt::Display for Tok {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Tok::Int(n) => write!(f, "`{n}`"),
            Tok::Float(x) => write!(f, "`{x:?}`"),
            Tok::Char(c) => write!(f, "`{c:?}`"),
            Tok::Str(_) => write!(f, "a string"),
            Tok::Ident(s) => write!(f, "`{s}`"),
            Tok::Unit(s) => write!(f, "the unit `<{s}>`"),
            Tok::Newline => write!(f, "a line break"),
            Tok::Eof => write!(f, "the end of the file"),
            t => write!(f, "`{}`", t.text()),
        }
    }
}
