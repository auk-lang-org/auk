/// `auk explain` (src/explain.rs): the error catalogue. Every diagnostic code in `diag.CODES`
/// has a page in docs/errors/<code>.md (what went wrong, a wrong and a fixed example, common
/// causes), embedded in the binary and rendered as plain text for a terminal.
///
/// The pages are embedded as Rust's `include_str!` does, with one `extern fn eNNNN(): str =
/// "#embed ../../docs/errors/ENNNN.md"` per page in `error_pages.auk`, which
/// scripts/gen_error_pages.sh generates from the directory (Rust lists the codes in a macro).
/// Embedding keeps `explain` working wherever the binary is installed, with no lookup on disk.

/// The markdown page for `code`.
pub fn page(code: str): str? uses ffi = error_pages.page(code)

/// `auk explain [code]`. Returns the exit code.
pub fn run(args: [str]): int uses ffi {
  if args.len() == 0 {
    print_raw(list())
    return 0
  }
  if args.len() > 1 {
    eprint("usage: auk explain [E0xxx]")
    return 2
  }
  let arg = args[0]
  let p = match normalize(arg) {
    some(c) => page(c)
    none => none
  }
  match p {
    some(md) => {
      print_raw(render(md))
      0
    }
    none => {
      eprint_raw(unknown(arg))
      1
    }
  }
}

/// `print!`: `s` (empty or ending in a line break) without a line break added.
fn print_raw(s: str) {
  if s != "" { print(s.strip_suffix("\n") else s) }
}

/// `eprint!`, likewise.
fn eprint_raw(s: str) {
  if s != "" { eprint(s.strip_suffix("\n") else s) }
}

/// Every code with its title, one per line.
pub fn list(): str {
  var out = ["Auk error codes (run `auk explain E0xxx` for details):\n\n"]
  for (c, t) in diag.CODES { out.push("  {c}  {t}\n") }
  out.join("")
}

/// `E0400`, `e0400`, `0400` and `400` all mean E0400.
fn normalize(arg: str): str? {
  let digits = arg.strip_prefix("E") else (arg.strip_prefix("e") else arg)
  // Rust's `u32` parse: ASCII digits after an optional `+`, at most four chars in all
  if digits == "" || digits.len() > 4 { return none }
  let body = digits.strip_prefix("+") else digits
  if body == "" || !body.chars().all(c => c.is_digit()) { return none }
  let n = int.parse(body) else return none
  some("E{n:04}")
}

/// The number of a registered code (`E0400` -> 400).
fn number(code: str): int = int.parse(code[1..code.len()]) else 0

/// The error for an unregistered code: the closest codes (by number), or codes whose title
/// mentions the word given.
fn unknown(arg: str): str {
  let shown = normalize(arg) else arg
  var out = ["error: `{shown}` is not an Auk error code\n"]
  let near = match normalize(arg) {
    some(c) => {
      let n = number(c)
      // a stable sort by distance, as Rust's `sort_by_key`
      diag.CODES.sort_by(x => abs(number(x.0) - n)).take(3)
    }
    none => {
      let w = arg.lower()
      diag.CODES.filter(x => x.1.lower().contains(w)).take(5)
    }
  }
  if near.len() > 0 {
    out.push("  closest codes:\n")
    for (c, t) in near { out.push("    {c}  {t}\n") }
  }
  out.push("  help: run `auk explain` to list every code\n")
  out.join("")
}

/// Markdown -> plain text: headings underlined, code blocks indented four spaces (a block for
/// another file of a project is headed by its path), everything else as written.
pub fn render(md: str): str {
  var out: [str] = []
  var in_code = false
  for line in md.lines() {
    match line.strip_prefix("```") {
      some(info) => {
        if !in_code {
          let parts = info.split()
          let lang = parts.get(0) else ""
          match parts.get(1) {
            some(path) => {
              let comment = if lang == "auk" { "//" } else { "#" }
              out.push("    {comment} {path}\n")
            }
            none => {}
          }
        }
        in_code = !in_code
        continue
      }
      none => {}
    }
    if in_code {
      out.push(if line == "" { "\n" } else { "    {line}\n" })
    } else if line.starts_with("# ") {
      let h = line[2..line.len()]
      let bar = "=".repeat(h.len())
      out.push("{h}\n{bar}\n")
    } else if line.starts_with("## ") {
      let h = line[3..line.len()]
      let bar = "-".repeat(h.len())
      out.push("{h}\n{bar}\n")
    } else {
      out.push(line + "\n")
    }
  }
  out.join("")
}

test "every code has a page with its title" {
  assert error_pages.CODES.len() == diag.CODES.len()
  for i, (c, t) in diag.CODES {
    assert error_pages.CODES[i] == c
    let p = page(c) else ""
    assert p.starts_with("# {c}: {t}\n")
  }
}

test "codes normalize" {
  for a in ["E0400", "e0400", "0400", "400"] { assert normalize(a) == some("E0400") }
  assert normalize("E") == none
  assert normalize("semicolon") == none
  assert normalize("E12345") == none
}

test "unknown codes suggest neighbours" {
  let u = unknown("E0206")
  assert u.contains("E0205") && u.contains("E0207")
  assert unknown("semicolon").contains("E0011")
}

test "render markdown" {
  let md = "# E1: t\n\ntext `x`\n\n## Wrong\n\n```auk\nfn f() {{\n\n}}\n```\n\n```toml raft.toml\n[package]\n```\n"
  assert render(md) ==
    "E1: t\n=====\n\ntext `x`\n\nWrong\n-----\n\n    fn f() {{\n\n    }}\n\n    # raft.toml\n    [package]\n"
}
