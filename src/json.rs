//! A minimal JSON value with a parser and a serializer, for the language server (`auk lsp`).
//! Numbers are `f64` (JSON-RPC ids and LSP positions are small integers); objects keep their
//! key order.

use std::fmt::Write;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

/// Build an object from `(key, value)` pairs.
pub fn obj<const N: usize>(pairs: [(&str, Json); N]) -> Json {
    Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

impl From<&str> for Json {
    fn from(s: &str) -> Json {
        Json::Str(s.to_string())
    }
}

impl From<String> for Json {
    fn from(s: String) -> Json {
        Json::Str(s)
    }
}

impl From<bool> for Json {
    fn from(b: bool) -> Json {
        Json::Bool(b)
    }
}

impl From<u32> for Json {
    fn from(n: u32) -> Json {
        Json::Num(f64::from(n))
    }
}

impl From<i64> for Json {
    fn from(n: i64) -> Json {
        Json::Num(n as f64)
    }
}

impl From<Vec<Json>> for Json {
    fn from(xs: Vec<Json>) -> Json {
        Json::Arr(xs)
    }
}

impl Json {
    /// The value of `key` in an object (`Null` if missing or not an object).
    pub fn get(&self, key: &str) -> &Json {
        static NULL: Json = Json::Null;
        match self {
            Json::Obj(kvs) => kvs.iter().find(|(k, _)| k == key).map(|(_, v)| v).unwrap_or(&NULL),
            _ => &NULL,
        }
    }

    /// Follow a chain of object keys.
    pub fn at(&self, path: &[&str]) -> &Json {
        path.iter().fold(self, |j, k| j.get(k))
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Num(n) if n.fract() == 0.0 => Some(*n as i64),
            _ => None,
        }
    }

    pub fn as_arr(&self) -> &[Json] {
        match self {
            Json::Arr(xs) => xs,
            _ => &[],
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Json::Null)
    }

    fn write(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Num(n) if !n.is_finite() => out.push_str("null"),
            Json::Num(n) if n.fract() == 0.0 && n.abs() < 1e15 => {
                let _ = write!(out, "{}", *n as i64);
            }
            Json::Num(n) => {
                let _ = write!(out, "{n}");
            }
            Json::Str(s) => write_str(s, out),
            Json::Arr(xs) => {
                out.push('[');
                for (i, x) in xs.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    x.write(out);
                }
                out.push(']');
            }
            Json::Obj(kvs) => {
                out.push('{');
                for (i, (k, v)) in kvs.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_str(k, out);
                    out.push(':');
                    v.write(out);
                }
                out.push('}');
            }
        }
    }
}

/// Compact serialization.
impl std::fmt::Display for Json {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        let mut out = String::new();
        self.write(&mut out);
        f.write_str(&out)
    }
}

fn write_str(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Parse one JSON value (surrounding whitespace allowed). The error says what and where (byte
/// offset).
pub fn parse(text: &str) -> Result<Json, String> {
    let mut p = Parser { s: text.as_bytes(), i: 0, depth: 0 };
    let v = p.value()?;
    p.ws();
    if p.i != p.s.len() {
        return Err(p.err("trailing characters"));
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
    depth: usize,
}

impl Parser<'_> {
    fn err(&self, what: &str) -> String {
        format!("invalid JSON at byte {}: {what}", self.i)
    }

    fn ws(&mut self) {
        while self.i < self.s.len() && matches!(self.s[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn eat(&mut self, c: u8) -> bool {
        if self.peek() == Some(c) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn lit(&mut self, word: &str, v: Json) -> Result<Json, String> {
        if self.s[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            Ok(v)
        } else {
            Err(self.err("unexpected word"))
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        self.ws();
        match self.peek() {
            None => Err(self.err("unexpected end")),
            Some(b'n') => self.lit("null", Json::Null),
            Some(b't') => self.lit("true", Json::Bool(true)),
            Some(b'f') => self.lit("false", Json::Bool(false)),
            Some(b'"') => self.string().map(Json::Str),
            Some(b'[') => self.nested(|p| {
                let mut xs = Vec::new();
                p.ws();
                if p.eat(b']') {
                    return Ok(Json::Arr(xs));
                }
                loop {
                    xs.push(p.value()?);
                    p.ws();
                    if p.eat(b']') {
                        return Ok(Json::Arr(xs));
                    }
                    if !p.eat(b',') {
                        return Err(p.err("expected `,` or `]`"));
                    }
                }
            }),
            Some(b'{') => self.nested(|p| {
                let mut kvs = Vec::new();
                p.ws();
                if p.eat(b'}') {
                    return Ok(Json::Obj(kvs));
                }
                loop {
                    p.ws();
                    if p.peek() != Some(b'"') {
                        return Err(p.err("expected a string key"));
                    }
                    let k = p.string()?;
                    p.ws();
                    if !p.eat(b':') {
                        return Err(p.err("expected `:`"));
                    }
                    kvs.push((k, p.value()?));
                    p.ws();
                    if p.eat(b'}') {
                        return Ok(Json::Obj(kvs));
                    }
                    if !p.eat(b',') {
                        return Err(p.err("expected `,` or `}`"));
                    }
                }
            }),
            Some(c) if c == b'-' || c.is_ascii_digit() => self.number(),
            Some(_) => Err(self.err("unexpected character")),
        }
    }

    /// `[` or `{`: skip it and parse the contents, with a nesting limit.
    fn nested(&mut self, f: impl FnOnce(&mut Self) -> Result<Json, String>) -> Result<Json, String> {
        self.depth += 1;
        if self.depth > 512 {
            return Err(self.err("nested too deeply"));
        }
        self.i += 1;
        let r = f(self);
        self.depth -= 1;
        r
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        self.eat(b'-');
        let digits = |p: &mut Self| {
            let s = p.i;
            while p.peek().is_some_and(|c| c.is_ascii_digit()) {
                p.i += 1;
            }
            p.i - s
        };
        if self.peek() == Some(b'0') {
            self.i += 1;
        } else if digits(self) == 0 {
            return Err(self.err("expected a digit"));
        }
        if self.eat(b'.') && digits(self) == 0 {
            return Err(self.err("expected a digit after `.`"));
        }
        if self.eat(b'e') || self.eat(b'E') {
            if !self.eat(b'+') {
                self.eat(b'-');
            }
            if digits(self) == 0 {
                return Err(self.err("expected an exponent"));
            }
        }
        let text = std::str::from_utf8(&self.s[start..self.i]).unwrap();
        text.parse::<f64>().map(Json::Num).map_err(|_| self.err("bad number"))
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let h = self.s.get(self.i..self.i + 4).ok_or_else(|| self.err("short \\u escape"))?;
        let h = std::str::from_utf8(h).ok().and_then(|h| u32::from_str_radix(h, 16).ok()).ok_or_else(|| self.err("bad \\u escape"))?;
        self.i += 4;
        Ok(h)
    }

    fn string(&mut self) -> Result<String, String> {
        self.i += 1; // the opening quote
        let mut out = String::new();
        loop {
            // copy a run of plain bytes (valid UTF-8, since the input is a &str)
            let start = self.i;
            while self.peek().is_some_and(|c| c != b'"' && c != b'\\' && c >= 0x20) {
                self.i += 1;
            }
            out.push_str(std::str::from_utf8(&self.s[start..self.i]).unwrap());
            match self.peek() {
                None => return Err(self.err("unterminated string")),
                Some(b'"') => {
                    self.i += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.i += 1;
                    let c = self.peek().ok_or_else(|| self.err("unterminated escape"))?;
                    self.i += 1;
                    match c {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                // a surrogate pair: `🦆`
                                if !(self.eat(b'\\') && self.eat(b'u')) {
                                    return Err(self.err("unpaired surrogate"));
                                }
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return Err(self.err("bad low surrogate"));
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else {
                                hi
                            };
                            out.push(char::from_u32(cp).ok_or_else(|| self.err("bad code point"))?);
                        }
                        _ => return Err(self.err("unknown escape")),
                    }
                }
                Some(_) => return Err(self.err("control character in string")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalars() {
        assert_eq!(parse(" null "), Ok(Json::Null));
        assert_eq!(parse("true"), Ok(Json::Bool(true)));
        assert_eq!(parse("false"), Ok(Json::Bool(false)));
        assert!(parse("nul").is_err());
        assert!(parse("").is_err());
        assert!(parse("1 2").is_err());
    }

    #[test]
    fn numbers() {
        assert_eq!(parse("0"), Ok(Json::Num(0.0)));
        assert_eq!(parse("-12"), Ok(Json::Num(-12.0)));
        assert_eq!(parse("3.25"), Ok(Json::Num(3.25)));
        assert_eq!(parse("1e3"), Ok(Json::Num(1000.0)));
        assert_eq!(parse("-2.5E-2"), Ok(Json::Num(-0.025)));
        assert_eq!(parse("42").unwrap().as_i64(), Some(42));
        assert_eq!(parse("4.5").unwrap().as_i64(), None);
        for bad in ["-", "1.", ".5", "1e", "+1", "0x10"] {
            assert!(parse(bad).is_err(), "{bad}");
        }
        assert_eq!(Json::Num(7.0).to_string(), "7");
        assert_eq!(Json::Num(-0.5).to_string(), "-0.5");
    }

    #[test]
    fn string_escapes() {
        assert_eq!(parse(r#""a\"b\\c\/d\n\t\r\b\f""#), Ok(Json::Str("a\"b\\c/d\n\t\r\u{8}\u{c}".into())));
        assert_eq!(parse(r#""é中""#), Ok(Json::Str("é中".into())));
        // a surrogate pair, and raw UTF-8
        assert_eq!(parse(r#""🦆 🦆""#), Ok(Json::Str("🦆 🦆".into())));
        assert!(parse(r#""\ud83e""#).is_err());
        assert!(parse(r#""\q""#).is_err());
        assert!(parse("\"a\nb\"").is_err());
        assert!(parse(r#""open"#).is_err());
        let s = "quote \" back \\ nl \n ctl \u{1} auk 🦆";
        assert_eq!(Json::Str(s.into()).to_string(), r#""quote \" back \\ nl \n ctl \u0001 auk 🦆""#);
        assert_eq!(parse(&Json::Str(s.into()).to_string()), Ok(Json::Str(s.into())));
    }

    #[test]
    fn nesting() {
        let v = parse(r#"{"a": [1, {"b": [true, null]}, []], "c": {}, "d": "x"}"#).unwrap();
        assert_eq!(v.at(&["a"]).as_arr().len(), 3);
        assert_eq!(v.get("a").as_arr()[1].get("b").as_arr()[0], Json::Bool(true));
        assert_eq!(v.get("d").as_str(), Some("x"));
        assert!(v.get("missing").is_null());
        assert_eq!(v.to_string(), r#"{"a":[1,{"b":[true,null]},[]],"c":{},"d":"x"}"#);
        assert!(parse("[1,]").is_err());
        assert!(parse(r#"{"a" 1}"#).is_err());
        assert!(parse("[[[").is_err());
        let deep = "[".repeat(1000) + &"]".repeat(1000);
        assert!(parse(&deep).is_err());
        assert_eq!(obj([("k", 1u32.into()), ("s", "v".into())]).to_string(), r#"{"k":1,"s":"v"}"#);
    }
}
