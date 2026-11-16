//! The TOML subset used by `quack.toml` and `quack.lock`: `[table]` and `[[array]]` headers,
//! `key = value` with basic strings, arrays and inline tables, and `#` comments.

/// A value: a string, an array, or an inline table.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    List(Vec<Value>),
    Table(Vec<(String, Value)>),
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        if let Value::Str(s) = self { Some(s) } else { None }
    }

    /// The value as an array of strings.
    pub fn as_strs(&self) -> Option<Vec<String>> {
        let Value::List(xs) = self else { return None };
        xs.iter().map(|x| x.as_str().map(String::from)).collect()
    }
}

/// A `[name]` table or one `[[name]]` element. The first table of a document is the root (`name` empty).
#[derive(Debug, Clone, PartialEq)]
pub struct Table {
    pub name: String,
    pub array: bool,
    pub entries: Vec<(String, Value)>,
}

impl Table {
    pub fn new(name: &str, array: bool) -> Table {
        Table { name: name.into(), array, entries: Vec::new() }
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }
}

pub type Doc = Vec<Table>;

/// Parse a document. Errors read `line N: message`.
pub fn parse(src: &str) -> Result<Doc, String> {
    let mut p = Parser { s: src.chars().collect(), i: 0, line: 1 };
    let mut doc = vec![Table::new("", false)];
    loop {
        p.skip_blank();
        match p.peek() {
            None => return Ok(doc),
            Some('[') => {
                p.i += 1;
                let array = p.eat('[');
                p.skip_ws();
                let name = p.key()?;
                p.skip_ws();
                if !p.eat(']') || (array && !p.eat(']')) {
                    return p.err("expected `]` after table name");
                }
                if !array && doc.iter().any(|t| t.name == name) {
                    return p.err(&format!("duplicate table [{name}]"));
                }
                doc.push(Table::new(&name, array));
            }
            Some(_) => {
                let key = p.key()?;
                p.skip_ws();
                if !p.eat('=') {
                    return p.err(&format!("expected `=` after `{key}`"));
                }
                p.skip_ws();
                let value = p.value()?;
                let table = doc.last_mut().unwrap();
                if table.get(&key).is_some() {
                    return p.err(&format!("duplicate key `{key}`"));
                }
                table.entries.push((key, value));
            }
        }
        p.end_line()?;
    }
}

struct Parser {
    s: Vec<char>,
    i: usize,
    line: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.s.get(self.i).copied()
    }

    fn eat(&mut self, c: char) -> bool {
        let hit = self.peek() == Some(c);
        if hit {
            self.i += 1;
        }
        hit
    }

    fn err<T>(&self, msg: &str) -> Result<T, String> {
        Err(format!("line {}: {msg}", self.line))
    }

    /// Skip spaces and tabs.
    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t')) {
            self.i += 1;
        }
    }

    /// Skip whitespace, newlines and comments.
    fn skip_blank(&mut self) {
        loop {
            self.skip_ws();
            match self.peek() {
                Some('\n') => self.line += 1,
                Some('\r') => {}
                Some('#') => {
                    while !matches!(self.peek(), None | Some('\n')) {
                        self.i += 1;
                    }
                    continue;
                }
                _ => return,
            }
            self.i += 1;
        }
    }

    /// After an item: optional comment, then a newline or end of input.
    fn end_line(&mut self) -> Result<(), String> {
        self.skip_ws();
        match self.peek() {
            None | Some('\n' | '\r' | '#') => Ok(()),
            Some(c) => self.err(&format!("unexpected `{c}`")),
        }
    }

    /// A bare (`A-Za-z0-9_-`) or quoted key.
    fn key(&mut self) -> Result<String, String> {
        if self.peek() == Some('"') {
            return self.string();
        }
        let start = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.') {
            self.i += 1;
        }
        if start == self.i {
            return self.err("expected a key");
        }
        Ok(self.s[start..self.i].iter().collect())
    }

    fn value(&mut self) -> Result<Value, String> {
        match self.peek() {
            Some('"') => Ok(Value::Str(self.string()?)),
            Some('[') => {
                self.i += 1;
                let mut xs = Vec::new();
                loop {
                    self.skip_blank();
                    if self.eat(']') {
                        return Ok(Value::List(xs));
                    }
                    xs.push(self.value()?);
                    self.skip_blank();
                    if !self.eat(',') && self.peek() != Some(']') {
                        return self.err("expected `,` or `]` in array");
                    }
                }
            }
            Some('{') => {
                self.i += 1;
                let mut entries: Vec<(String, Value)> = Vec::new();
                self.skip_ws();
                if self.eat('}') {
                    return Ok(Value::Table(entries));
                }
                loop {
                    self.skip_ws();
                    let key = self.key()?;
                    self.skip_ws();
                    if !self.eat('=') {
                        return self.err(&format!("expected `=` after `{key}`"));
                    }
                    self.skip_ws();
                    if entries.iter().any(|(k, _)| *k == key) {
                        return self.err(&format!("duplicate key `{key}`"));
                    }
                    entries.push((key, self.value()?));
                    self.skip_ws();
                    if self.eat('}') {
                        return Ok(Value::Table(entries));
                    }
                    if !self.eat(',') {
                        return self.err("expected `,` or `}` in inline table");
                    }
                }
            }
            _ => self.err("expected a value (quack.toml supports strings, arrays and inline tables)"),
        }
    }

    /// A `"basic string"` with `\" \\ \n \t \r \uXXXX` escapes.
    fn string(&mut self) -> Result<String, String> {
        self.i += 1;
        let mut out = String::new();
        loop {
            let Some(c) = self.peek() else { return self.err("unterminated string") };
            self.i += 1;
            match c {
                '"' => return Ok(out),
                '\n' => return self.err("unterminated string"),
                '\\' => {
                    let e = self.peek();
                    self.i += 1;
                    out.push(match e {
                        Some('"') => '"',
                        Some('\\') => '\\',
                        Some('n') => '\n',
                        Some('t') => '\t',
                        Some('r') => '\r',
                        Some('u') => {
                            let hex: String = self.s.iter().skip(self.i).take(4).collect();
                            self.i += 4;
                            match u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                                Some(c) if hex.len() == 4 => c,
                                _ => return self.err("bad \\u escape"),
                            }
                        }
                        _ => return self.err("bad escape in string"),
                    });
                }
                c => out.push(c),
            }
        }
    }
}

/// Render a value in the form `parse` reads back.
pub fn value_str(v: &Value) -> String {
    match v {
        Value::Str(s) => {
            let mut out = String::from('"');
            for c in s.chars() {
                match c {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\t' => out.push_str("\\t"),
                    '\r' => out.push_str("\\r"),
                    c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
                    c => out.push(c),
                }
            }
            out.push('"');
            out
        }
        Value::List(xs) => format!("[{}]", xs.iter().map(value_str).collect::<Vec<_>>().join(", ")),
        Value::Table(es) if es.is_empty() => "{}".into(),
        Value::Table(es) => {
            let es: Vec<_> = es.iter().map(|(k, v)| format!("{} = {}", key_str(k), value_str(v))).collect();
            format!("{{ {} }}", es.join(", "))
        }
    }
}

fn key_str(k: &str) -> String {
    let bare = !k.is_empty() && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    if bare { k.into() } else { value_str(&Value::Str(k.into())) }
}

/// Render a document, one blank line between tables.
pub fn write(doc: &Doc) -> String {
    let mut out = String::new();
    for t in doc {
        if t.name.is_empty() && t.entries.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push('\n');
        }
        if !t.name.is_empty() {
            let (l, r) = if t.array { ("[[", "]]") } else { ("[", "]") };
            out.push_str(&format!("{l}{}{r}\n", t.name));
        }
        for (k, v) in &t.entries {
            out.push_str(&format!("{} = {}\n", key_str(k), value_str(v)));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const MANIFEST: &str = r#"# a comment
[package]
name = "weather"   # trailing comment
version = "0.1.0"
effects = ["net", "fs"]

[deps]
http = "^0.1"
geo  = { path = "../geo" }
"quoted key" = "a \"b\" \\ é"
multi = [
  "x",   # comment inside an array
  "y",
]

[[package]]
name = "a"

[[package]]
name = "b"
"#;

    #[test]
    fn parse_manifest() {
        let doc = parse(MANIFEST).unwrap();
        let names: Vec<_> = doc.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["", "package", "deps", "package", "package"]);
        assert_eq!(doc[1].get("name").unwrap().as_str(), Some("weather"));
        assert_eq!(doc[1].get("effects").unwrap().as_strs().unwrap(), ["net", "fs"]);
        let geo = Value::Table(vec![("path".into(), Value::Str("../geo".into()))]);
        assert_eq!(doc[2].get("geo"), Some(&geo));
        assert_eq!(doc[2].get("quoted key").unwrap().as_str(), Some("a \"b\" \\ é"));
        assert_eq!(doc[2].get("multi").unwrap().as_strs().unwrap(), ["x", "y"]);
        assert!(doc[3].array && doc[4].array);
    }

    #[test]
    fn round_trip() {
        let doc = parse(MANIFEST).unwrap();
        let text = write(&doc);
        assert_eq!(parse(&text).unwrap(), doc);
        assert_eq!(write(&parse(&text).unwrap()), text);
        assert!(text.contains("geo = { path = \"../geo\" }\n"));
    }

    #[test]
    fn errors() {
        assert_eq!(
            parse("a = 1").unwrap_err(),
            "line 1: expected a value (quack.toml supports strings, arrays and inline tables)"
        );
        assert_eq!(parse("\n\na = \"x").unwrap_err(), "line 3: unterminated string");
        assert_eq!(parse("a = \"x\"\na = \"y\"").unwrap_err(), "line 2: duplicate key `a`");
        assert_eq!(parse("[t]\n[t]").unwrap_err(), "line 2: duplicate table [t]");
        assert_eq!(parse("a = \"x\" b").unwrap_err(), "line 1: unexpected `b`");
    }
}
