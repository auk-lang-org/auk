/// tests/explain.rs: the error catalogue: every registered code has a page in docs/errors/,
/// every page's wrong example produces exactly its code and its fixed example checks clean
/// (run through the real binary), and `auk explain` renders, lists and suggests.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("every_code_has_a_page", every_code_has_a_page),
  t.test(
    "examples_trigger_their_code_and_fixes_check_clean",
    examples_trigger_their_code_and_fixes_check_clean,
  ),
  t.test("explain_renders_a_page", explain_renders_a_page),
  t.test("explain_lists_every_code", explain_lists_every_code),
  t.test("explain_unknown_code_suggests_closest", explain_unknown_code_suggests_closest),
  t.test("diagnostics_point_to_explain", diagnostics_point_to_explain),
]

/// Codes whose wrong example can't produce them from user code (the page explains why).
/// E0114: only an `extern` in the core prelude can name an intrinsic (a user `extern fn`'s
/// string is a C prototype).
let UNREACHABLE = ["E0114"]

/// Codes below E0100 that `auk check` reports, not the parser: they need the manifest (E0036,
/// the `ffi` effect) or the types (E0040, C prototypes).
let CHECKED = ["E0036", "E0040"]

/// Codes reported while building, not by `auk check`: E0420 (an imprint panicked while it was
/// computed at compile time). Their wrong example checks clean and fails `auk ir` with the
/// code; their fixed example also builds.
let BUILD_TIME = ["E0420"]

fn auk(args: [str]): cmd.Out uses env, ffi, time = t.auk().args(args).output()

/// (code, title) for every registered code, from `auk explain`'s listing.
fn codes(): [(str, str)] uses env, ffi, time {
  let out = auk(["explain"])
  assert out.success()
  var codes: [(str, str)] = []
  for l in out.stdout.lines() {
    let l = l.strip_prefix("  ") else continue
    let i = l.find("  ") else continue
    codes.push((l[0..i], l[i + 2..l.len()]))
  }
  t.check(codes.len() >= 100, "{codes}")
  codes
}

fn page(code: str): str uses fs = t.read("docs/errors/{code}.md")

/// The fenced blocks under each `## ` heading: (heading, [(path, source)]), where the path is
/// empty for the main file.
fn sections(md: str): [(str, [(str, str)])] {
  var secs: [(str, [(str, str)])] = []
  var block: (str, str)? = none
  for line in md.lines() {
    match block {
      some((path, src)) => if line.starts_with("```") {
        t.check(secs.len() > 0, "a code block before any section")
        secs[secs.len() - 1].1.push((path, src))
        block = none
      } else {
        block = some((path, src + line + "\n"))
      }
      none => match line.strip_prefix("## ") {
        some(h) => secs.push((h, []))
        none => match line.strip_prefix("```") {
          some(info) => {
            let path = info.split().get(1) else ""
            block = some((path, ""))
          }
          none => {}
        }
      }
    }
  }
  t.check(block is none, "unclosed code block")
  secs
}

fn section(secs: [(str, [(str, str)])], name: str): [(str, str)] = match secs.find(
  s => s.0 == name,
) {
  some(s) => s.1
  none => t.bail("no `## {name}` section")
}

/// Write `files` to a fresh directory and return it and the main file: `t.auk` for a lone
/// file, or `src/main.auk` of a project when any block names a path.
fn materialize(files: [(str, str)], tag: str): (str, str) uses fs, ffi {
  let dir = t.temp("auk-explain-{tag}")
  let project = files.any(f => f.0 != "")
  let main = paths.join(dir, if project { "src/main.auk" } else { "t.auk" })
  for (p, src) in files {
    let path = if p == "" { main } else { paths.join(dir, p) }
    t.write(path, src)
  }
  (dir, main)
}

/// The diagnostic codes of a `--json` report, in order.
fn json_codes(js: str): [str] = js.split("\"code\":\"").skip(1).map(s => s[0..5])

/// The diagnostic codes `auk ir` reports on the files, and its stderr.
fn build_codes(files: [(str, str)], tag: str): ([str], str) uses env, fs, ffi, time {
  let (dir, main) = materialize(files, tag)
  let out = auk(["ir", main])
  t.rm_rf(dir)
  let err = out.stderr
  (err.split("error[").skip(1).map(s => s[0..5]), err)
}

/// Run `auk parse --json` (lexing and parsing codes) or `auk check --json` on the files.
fn diagnose(files: [(str, str)], parse: bool, tag: str): ([str], str) uses env, fs, ffi, time {
  let (dir, main) = materialize(files, tag)
  let out = if parse { auk(["parse", "--json", main]) } else { auk(["check", main, "--json"]) }
  t.rm_rf(dir)
  (json_codes(out.stdout), out.stdout + out.stderr)
}

fn every_code_has_a_page() uses env, fs, ffi, time {
  let codes = codes()
  var bad: [str] = []
  for (code, title) in codes {
    let md = page(code)
    let secs = sections(md)
    let heads = secs.map(s => s.0)
    if !md.starts_with("# {code}: {title}\n") {
      bad.push("{code}: must start with `# {code}: {title}`")
    }
    if heads != ["Wrong", "Fixed", "Common causes"] { bad.push("{code}: sections are {heads}") }
    let causes = md.split("## Common causes")
    if !(causes.len() > 1 && causes[1].contains("\n- ")) {
      bad.push("{code}: no common causes listed")
    }
    if md.lines().len() > 45 {
      bad.push("{code}: {md.lines().len()} lines (keep it under about 40)")
    }
  }
  // no stray pages
  for name in t.must(fs.list("docs/errors"), "docs/errors") {
    let code = name.strip_suffix(".md") else name
    if !codes.any(c => c.0 == code) { bad.push("docs/errors/{name} is not a registered code") }
  }
  t.check(bad.len() == 0, bad.join("\n"))
}

/// Each wrong example produces exactly its code (E00xx through `auk parse`, the rest through
/// `auk check`); each fixed example (the wrong one's files, with the fixed blocks replacing or
/// adding files) checks with no diagnostics at all.
fn examples_trigger_their_code_and_fixes_check_clean() uses env, fs, ffi, time {
  let codes = codes()
  let no_parse = t.lacks("parse", "the wrong examples of lexing and parsing codes")
  let no_ir = t.lacks("ir", "building the examples of build-time codes")
  var bad: [str] = []
  for (code, _) in codes {
    let secs = sections(page(code))
    let wrong = section(secs, "Wrong")
    var fixed = wrong
    for (p, src) in section(secs, "Fixed") {
      match fixed.find_index(f => f.0 == p) {
        some(i) => fixed[i] = (p, src)
        none => fixed.push((p, src))
      }
    }
    t.check(wrong.any(f => f.0 == ""), "{code}: the wrong example has no main block")

    let parse = code < "E0100" && !CHECKED.contains(code)
    // without `parse`, a lexing or parsing code is taken as produced (not checked)
    let (got, out) = if parse && no_parse {
      ([code], "")
    } else {
      diagnose(wrong, parse, "{code}-w")
    }
    let want = [code]
    if BUILD_TIME.contains(code) && no_ir {
      if got.len() > 0 {
        bad.push("{code}: `auk check` on the wrong example gives {got}, want none:\n{out}")
      }
    } else if BUILD_TIME.contains(code) {
      if got.len() > 0 {
        bad.push("{code}: `auk check` on the wrong example gives {got}, want none:\n{out}")
      }
      let (got, err) = build_codes(wrong, "{code}-bw")
      if got != want {
        bad.push("{code}: building the wrong example gives {got}, want {want}:\n{err}")
      }
      let (got, err) = build_codes(fixed, "{code}-bf")
      if got.len() > 0 { bad.push("{code}: building the fixed example gives {got}:\n{err}") }
    } else if UNREACHABLE.contains(code) {
      if got.contains(code) {
        bad.push("{code} is listed as unreachable but its example produces it; remove it from UNREACHABLE")
      }
    } else if got != want {
      bad.push("{code}: the wrong example gives {got}, want {want}:\n{out}")
    }

    let (got, out) = diagnose(fixed, false, "{code}-f")
    if got.len() > 0 || !out.contains("\"ok\":true") {
      bad.push("{code}: the fixed example gives {got}:\n{out}")
    }
  }
  t.check(bad.len() == 0, "{bad.len()} problem(s):\n{bad.join("\n")}")
}

fn explain_renders_a_page() uses env, ffi, time {
  let out = auk(["explain", "E0400"])
  assert out.success()
  let s = out.stdout
  t.check(
    s.starts_with("E0400: patterns don't cover every case\n======================================\n"),
    s,
  )
  t.check(s.contains("\nWrong\n-----\n\n    enum Shape {{"), s)
  t.check(s.contains("\n      Circle(r) => 3.14 * r * r\n"), s)
  t.check(s.contains("\nCommon causes\n-------------\n"), s)
  t.check(!s.contains("```") && !s.contains("## "), s)
  // codes are accepted in any case and without the leading zeros
  for alias in ["e0400", "400", "0400"] { t.eq(auk(["explain", alias]).stdout, s, alias) }
  // a project page shows each extra file's path
  let s = auk(["explain", "E0413"]).stdout
  t.check(s.contains("    # raft.toml\n    [package]\n"), s)
}

fn explain_lists_every_code() uses env, ffi, time {
  let out = auk(["explain"])
  assert out.success()
  let s = out.stdout
  t.check(s.contains("  E0011  semicolons are not used\n"), s)
  t.check(s.contains("  E0415  "), s)
  assert s.lines().filter(l => l.starts_with("  E0")).len() == codes().len()
}

fn explain_unknown_code_suggests_closest() uses env, ffi, time {
  let out = auk(["explain", "E0206"])
  assert out.code == some(1)
  let e = out.stderr
  t.check(e.starts_with("error: `E0206` is not an Auk error code\n"), e)
  t.check(e.contains("E0205") && e.contains("E0207"), e)
  t.check(e.contains("auk explain"), e)
  // a word searches the titles
  let e = auk(["explain", "semicolons"]).stderr
  t.check(e.contains("E0011  semicolons are not used"), e)
  assert auk(["explain", "E0001", "E0002"]).code == some(2)
}

fn diagnostics_point_to_explain() uses env, fs, ffi, time {
  let dir = t.temp("auk-explain-help")
  let p = paths.join(dir, "t.auk")
  t.write(p, "fn label(n: int): str = n\n")
  let err = auk(["check", p]).stderr
  t.check(err.ends_with("  = help: run `auk explain E0200` for details\n"), err)
  let js = auk(["check", p, "--json"]).stdout
  t.check(js.contains("\"explain\":\"auk explain E0200\"}}"), js)
  if !t.lacks("parse", "a parse error's pointer to `auk explain`") {
    t.write(p, "fn main() {{\n  let x = 1;\n}}\n")
    let err = auk(["parse", p]).stderr
    t.check(err.ends_with("  = help: run `auk explain E0011` for details\n"), err)
  }
  t.rm_rf(dir)
  t.check(
    fs.exists("docs/errors/E0200.md") && !fs.is_dir("docs/errors/E0200.md"),
    "docs/errors/E0200.md",
  )
}
