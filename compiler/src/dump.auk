/// The `auk dump tokens|ast` text (src/dump.rs): one node per line, children indented by two
/// spaces, strings escaped by `esc`, floats as their IEEE bits, chars as code points.

/// A string in double quotes: `\\ \" \n \t \r` escaped, other control chars as `\u{hex}`,
/// everything else as is.
pub fn esc(s: str): str {
  var plain = true
  for c in s.chars() {
    if c == '\\' || c == '"' || int(c) < 0x20 || int(c) == 0x7f {
      plain = false
      break
    }
  }
  if plain { return "\"" + s + "\"" }
  var out: [str] = ["\""]
  for c in s.chars() {
    match c {
      '\\' => out.push("\\\\")
      '"' => out.push("\\\"")
      '\n' => out.push("\\n")
      '\t' => out.push("\\t")
      '\r' => out.push("\\r")
      _ when int(c) < 0x20 || int(c) == 0x7f => out.push("\\u{{{hex(int(c))}}}")
      _ => out.push(str(c))
    }
  }
  out.push("\"")
  out.join("")
}

fn hex(n: int): str {
  let ds = "0123456789abcdef".chars()
  if n < 16 { return str(ds[n]) }
  hex(n / 16) + str(ds[n % 16])
}

pub fn sp(s: diag.Span): str = "{s.line}:{s.col}-{s.end_line}:{s.end_col}"

pub fn line(out: var [str], depth: int, s: str) {
  if depth == 0 {
    out.push(s)
  } else {
    out.push("  ".repeat(depth) + s)
  }
}

pub fn diag_dump(out: var [str], d: diag.Diag) {
  line(&out, 0, "error {d.code} {sp(d.span)} {esc(d.message)}")
  for n in d.notes { line(&out, 1, "note {esc(n)}") }
  for f in d.fixes { line(&out, 1, "fix {sp(f.span)} {esc(f.text)}") }
}

// ---- tokens ----

pub fn tokens(out: var [str], module_doc: str?, toks: [token.Token]) {
  match module_doc {
    some(d) => line(&out, 0, "module-doc {esc(d)}")
    none => {}
  }
  toks_at(&out, 0, toks)
}

fn toks_at(out: var [str], depth: int, toks: [token.Token]) {
  for t in toks {
    var s = "{sp(t.span)} {tok_text(t.tok)}"
    if t.space_before { s += " space" }
    match t.doc {
      some(d) => s += " doc={esc(d)}"
      none => {}
    }
    line(&out, depth, s)
    match t.tok {
      Str(parts) => for p in parts {
        match p {
          Lit(l) => line(&out, depth + 1, "lit {esc(l)}")
          Interp(ts, spec, span) => {
            let sp2 = match spec {
              some(s) => " spec={esc(s)}"
              none => ""
            }
            line(&out, depth + 1, "interp {sp(span)}{sp2}")
            toks_at(&out, depth + 2, ts)
          }
        }
      }
      _ => {}
    }
  }
}

/// The token's kind (its variant name) and payload.
pub fn tok_text(t: token.Tok): str = match t {
  Int(n) => "Int {token.uint_str(n)}"
  Float(x) => "Float {x.bits()}"
  Char(c) => "Char {int(c)}"
  Ident(s) => "Ident {esc(s)}"
  Unit(s) => "Unit {esc(s)}"
  _ => t.name()
}
