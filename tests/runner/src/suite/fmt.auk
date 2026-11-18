/// tests/fmt.rs: `auk fmt` over every corpus file (`examples/*.auk` plus
/// `packages/*/src/*.auk`): the output parses, the AST is unchanged, formatting is idempotent,
/// no comment is lost, and the corpus itself is already in canonical form. (The Rust tests
/// always run the Rust `auk`; on a binary that lacks `parse`, the AST comparison is skipped.)

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("comment_counter", comment_counter),
  t.test("corpus_formats_safely", corpus_formats_safely),
  t.test("check_mode_and_files", check_mode_and_files),
  t.test("parse_errors_leave_the_file_untouched", parse_errors_leave_the_file_untouched),
]

fn auk(args: [str], stdin: str?): cmd.Out uses env, ffi, time =
  t.auk().args(args).stdin(stdin else "").output()

fn corpus(): [str] uses fs {
  var files = t.auk_files("examples")
  let pkgs = t
    .must(fs.list("packages"), "packages")
    .sort()
    .map(n => "packages/{n}/src")
    .filter(p => fs.is_dir(p))
  for p in pkgs { files = files + t.auk_files(p) }
  files
}

/// A file with `src` in a fresh temporary directory (unique per `tag`).
fn scratch(src: str, tag: str): str uses fs, ffi {
  let d = t.temp("auk-fmt-{tag}")
  let path = paths.join(d, "t.auk")
  t.write(path, src)
  path
}

/// `auk fmt -`: the formatted text.
fn format(src: str, name: str): str uses env, ffi, time {
  let out = auk(["fmt", "-"], some(src))
  t.check(out.success(), "auk fmt failed on {name}:\n{out.stderr}")
  out.stdout
}

/// `auk parse --ast` of a source text (spans and node ids are not in the dump).
fn ast(src: str, name: str, tag: str): str uses env, fs, ffi, time {
  let path = scratch(src, tag)
  let out = auk(["parse", "--ast", path], none)
  t.rm_rf(paths.parent(path)!)
  t.check(out.success(), "{name} does not parse:\n{out.stderr}\n--- source ---\n{src}")
  out.stdout
}

/// The number of `//` and `/*` comments outside string and char literals.
fn count_comments(src: str): int {
  let cs = src.chars()
  var i = 0
  var n = 0
  code(cs, &i, &n, false)
  n
}

fn at(cs: [char], k: int): char? = cs.get(k)

fn starts3(cs: [char], i: int): bool =
  at(cs, i) == some('"') && at(cs, i + 1) == some('"') && at(cs, i + 2) == some('"')

fn is_word(c: char): bool = c.is_alpha() || c.is_digit() || c == '_' || int(c) > 127

/// Scan code from `i`, counting comments, up to the end (or the `}` closing an
/// interpolation, when `interp`).
fn code(cs: [char], i: var int, n: var int, interp: bool) {
  var depth = 0
  while i < cs.len() {
    let c = cs[i]
    if c == '/' && at(cs, i + 1) == some('/') {
      n += 1
      while i < cs.len() && cs[i] != '\n' { i += 1 }
    } else if c == '/' && at(cs, i + 1) == some('*') {
      n += 1
      var d = 0
      loop {
        if at(cs, i) == some('/') && at(cs, i + 1) == some('*') {
          d += 1
          i += 2
        } else if at(cs, i) == some('*') && at(cs, i + 1) == some('/') {
          d -= 1
          i += 2
          if d == 0 { break }
        } else if i >= cs.len() {
          break
        } else {
          i += 1
        }
      }
    } else if c == '"' ||
      (c == 'r' && at(cs, i + 1) == some('"') && (i == 0 || !is_word(cs[i - 1]))) {
      string(cs, &i, &n)
    } else if c == '\'' {
      // a char literal: 'a', '\n', '\u{1F986}', '\''
      i += 1
      while i < cs.len() && cs[i] != '\'' { i += if cs[i] == '\\' { 2 } else { 1 } }
      i += 1
    } else {
      if interp {
        if c == '{' {
          depth += 1
        } else if c == '}' && depth == 0 {
          return
        } else if c == '}' {
          depth -= 1
        }
      }
      i += 1
    }
  }
}

/// Skip a string literal at `i` (`"..."`, `"""..."""`, raw forms), scanning interpolations
/// as code.
fn string(cs: [char], i: var int, n: var int) {
  let raw = cs[i] == 'r'
  if raw { i += 1 }
  let triple = starts3(cs, i)
  i += if triple { 3 } else { 1 }
  while i < cs.len() {
    let c = cs[i]
    if triple && starts3(cs, i) {
      i += 3
      return
    }
    if !triple && c == '"' {
      i += 1
      return
    }
    if !raw && (c == '\\' || (c == '{' && at(cs, i + 1) == some('{'))) {
      // an escape or a literal `{{`
      i += 2
    } else if !raw && c == '{' {
      i += 1
      code(cs, &i, &n, true)
      i += 1
    } else {
      i += 1
    }
  }
}

fn comment_counter() {
  assert count_comments("// a\nfn f() = 1 /* b /* nested */ */\n/// doc") == 3
  assert count_comments(r"""let u = "http://x" + r"a//b" + '/'.str() + "{a["//"]}" // c""") == 1
  assert count_comments("let s = \"\"\"\n  // not a comment\n  \"\"\"") == 0
}

fn corpus_formats_safely() uses env, fs, ffi, time {
  let files = corpus()
  t.check(files.len() >= 17, "corpus too small: {files}")
  let no_parse = t.lacks("parse", "comparing the formatted corpus's AST with the original's")
  var canonical: [str] = []
  for k, name in files {
    let src = t.read(name)
    let once = format(src, name)
    // the output parses to the same AST
    if !no_parse {
      t.eq(
        ast(src, name, "{k}a"),
        ast(once, "{name} (formatted)", "{k}b"),
        "{name}: formatting changed the AST",
      )
    }
    // idempotent
    let twice = format(once, name)
    t.eq(once, twice, "{name}: formatting is not idempotent")
    // no comment lost or invented
    t.check(count_comments(src) == count_comments(once), "{name}: comment count changed")
    if once == src { canonical.push(name) }
  }
  // (Rust prints "N of M corpus files are in canonical form", captured by the harness)
  // the corpus is kept fmt-clean
  t.check(canonical.len() == files.len(), "not fmt-clean: run `auk fmt examples packages`")
}

fn check_mode_and_files() uses env, fs, ffi, time {
  let ugly = "fn f( a:int ):int=a+1\n"
  let p = scratch(ugly, "check")
  // --check lists the file, exits 1 and leaves it alone
  let out = auk(["fmt", "--check", p], none)
  assert out.code == some(1)
  assert out.stdout.trim() == p
  assert t.read(p) == ugly
  // fmt rewrites it in place; then --check is clean
  assert auk(["fmt", p], none).success()
  assert t.read(p) == "fn f(a: int): int = a + 1\n"
  let out = auk(["fmt", "--check", p], none)
  assert out.code == some(0)
  assert out.stdout == ""
  t.rm_rf(paths.parent(p)!)
}

fn parse_errors_leave_the_file_untouched() uses env, fs, ffi, time {
  let bad = "fn f() {{\n  let x = 1;\n}}\n"
  let p = scratch(bad, "bad")
  let out = auk(["fmt", p], none)
  assert out.code == some(1)
  t.check(out.stderr.contains("E0011"), "expected the parse diagnostic, got:\n{out.stderr}")
  assert t.read(p) == bad
  t.rm_rf(paths.parent(p)!)
  // stdin too
  let out = auk(["fmt", "-"], some(bad))
  assert out.code == some(1)
  assert out.stdout == ""
}
