/// Glob patterns for paths: `*`, `?`, `[...]`, `**` and `{a,b}`. Matching is pure; only `walk`
/// and `find`, which list directories, use `fs`. Paths use `/` separators, and matching is
/// case-sensitive. A wildcard never matches a `/`, and never matches a leading `.` (hidden
/// files) unless the pattern spells the dot out.

// One token of a path segment pattern.
enum Tok {
  Lit(c: char),
  One,                              // ?
  Star,                             // *
  Class(neg: bool, ranges: [int]),  // [a-z_] as flat [lo, hi, lo, hi, ...] code points
}

// One `/`-separated part of a pattern.
enum Seg { Deep, Part(toks: [Tok]) }  // Deep is `**`: zero or more whole segments

/// A compiled pattern, for matching many paths: `let g = glob.compile("**/*.auk")`. Every
/// string is a valid pattern (see `matches`), so compiling never fails.
pub struct Glob { rooted: bool, alts: [[Seg]] }

/// Compiles a pattern once: `{a,b}` alternatives are expanded and each `/`-separated part is
/// tokenized.
pub fn compile(pattern: str): Glob {
  let cs = pattern.chars()
  let alts = if pattern.contains('{') { expand_chars(cs).map(segs_of) } else { [segs_of(cs)] }
  Glob { rooted: pattern.starts_with("/"), alts }
}

/// Does `path` match `pattern`? Syntax:
/// - `?` any one char, `*` any run of chars (both within one path segment, never `/`)
/// - `[abc]`, `[a-z0-9]`, `[!a]` or `[^a]` one char from (or not from) a set; `]` first in the
///   set is literal, as is `-` first or last
/// - `**` as a whole segment: zero or more segments (`src/**/*.auk` also matches `src/a.auk`)
/// - `{a,b,c}` alternatives, which may nest and may contain `/` and other wildcards
/// - `\x` matches `x` literally
/// An unclosed `[` or a `{` without a top-level `,` and closing `}` is matched literally. Hidden
/// segments (starting with `.`) only match a pattern segment that starts with a literal `.`.
/// Leading `./` and repeated `/` are ignored on both sides; a pattern starting with `/` matches
/// only absolute paths and vice versa. A trailing `/` is ignored.
pub fn matches(pattern: str, path: str): bool = matches(compile(pattern), path)
/// `matches` with a compiled pattern.
pub fn matches(g: Glob, path: str): bool {
  if path.starts_with("/") != g.rooted { return false }
  let cs = path.chars()
  let bs = bounds(cs)
  for a in g.alts { if match_segs(a, 0, cs, bs, 0) { return true } }
  false
}

/// Does `s` use any glob syntax (`* ? [ { \`)? A string without it only matches itself.
pub fn is_pattern(s: str): bool =
  s.contains('*') || s.contains('?') || s.contains('[') || s.contains('{') || s.contains('\\')

/// `s` with every glob special char escaped, so it matches only itself: `escape("a*b") == "a\\*b"`.
pub fn escape(s: str): str {
  if !(is_pattern(s) || s.contains(']') || s.contains('}') || s.contains(',')) { return s }
  let cs = s.chars()
  var out = ""
  var from = 0  // start of the chars not copied yet
  for i, c in cs {
    if "*?[]{{}}\\,".contains(c) {
      out += str(cs[from..i])
      out += "\\"
      from = i
    }
  }
  out + str(cs[from..cs.len()])
}

// ---- walking the file system ----

/// The deepest directory level `walk` descends to (guards against symlink cycles, which `fs`
/// can't detect).
pub let MAX_DEPTH = 64

/// Every file and directory under `dir` whose path relative to `dir` matches `pattern`, e.g.
/// `walk("src", "**/*.auk")` -> `["lib.auk", "net/tcp.auk"]`. Paths are relative to `dir`,
/// joined with `/`, in walk order (each directory's entries sorted by name, a directory's
/// contents right after it). Only directories that could still match are opened, so hidden
/// directories like `.git` are skipped unless the pattern names them. Symlinks are followed.
pub fn walk(dir: str, pattern: str): [str]! uses fs {
  let g = compile(pattern)
  var out: [str] = []
  visit(dir.trim_end_slash(), "", [], [], g, &out)?
  out
}

/// Every path matching a pattern that starts with its own base directory, relative to the
/// working directory: `find("src/**/*.auk")` walks `src` and returns `src/...` paths.
/// A pattern without glob syntax gives `[pattern]` if that path exists, else `[]`.
pub fn find(pattern: str): [str]! uses fs {
  if !is_pattern(pattern) { return if fs.exists(pattern) { [pattern] } else { [] } }
  let parts = pattern.split("/")
  let n = parts.find_index(p => is_pattern(p))!
  let base = parts.take(n).join("/")
  let rest = parts.skip(n).join("/")
  if n == 0 { return walk(".", pattern) }
  let root = if base == "" { "/" } else { base }  // "/x/*": base "" means the root
  if !fs.is_dir(root) { return [] }
  let prefix = if root.ends_with("/") { root } else { root + "/" }
  (walk(root, rest)?).map(p => prefix + p)
}

// `cs` and `bs` are the segments of `rel`: the names' chars and their bounds (see `bounds`).
fn visit(dir: str, rel: str, cs: [char], bs: [int], g: Glob, out: var [str]): ()! uses fs {
  if bs.len() / 2 >= MAX_DEPTH { return }
  let here = if rel == "" { dir } else { dir + "/" + rel }
  for name in fs.list(here)? {
    let r = if rel == "" { name } else { rel + "/" + name }
    let s = cs + name.chars()
    let b = bs + [cs.len(), s.len()]
    if g.alts.any(a => match_segs(a, 0, s, b, 0)) { out.push(r) }
    if g.alts.any(a => can_extend(a, 0, s, b, 0)) && fs.is_dir(here + "/" + name) {
      visit(dir, r, s, b, g, &out)?
    }
  }
}

fn trim_end_slash(s: str): str {
  var t = s
  while t.len() > 1 && t.ends_with("/") { t = t[0..t.len() - 1] }
  t
}

// ---- matching ----

// The path segments of `cs`, without empty ones and a leading `.`, as a flat list of
// start/end index pairs.
fn bounds(cs: [char]): [int] {
  let n = cs.len()
  var bs: [int] = []
  var a = 0
  var dot = false  // a leading `.` segment has been dropped
  for i in 0..=n {
    if i < n && cs[i] != '/' { continue }
    if i > a {
      if !dot && bs.len() == 0 && i == a + 1 && cs[a] == '.' {
        dot = true
      } else {
        bs.push(a)
        bs.push(i)
      }
    }
    a = i + 1
  }
  bs
}

// Segment `si` of a path is `cs[bs[2 * si]..bs[2 * si + 1]]`.
fn match_segs(ps: [Seg], pi: int, cs: [char], bs: [int], si: int): bool {
  let n = bs.len() / 2
  if pi == ps.len() { return si == n }
  match ps[pi] {
    Deep => {
      var k = si
      loop {
        if match_segs(ps, pi + 1, cs, bs, k) { return true }
        if k == n || hidden(cs, bs, k) { return false }
        k += 1
      }
    }
    Part(toks) => si < n &&
      match_part(toks, cs, bs[2 * si], bs[2 * si + 1]) &&
      match_segs(ps, pi + 1, cs, bs, si + 1)
  }
}

fn hidden(cs: [char], bs: [int], si: int): bool =
  bs[2 * si + 1] > bs[2 * si] && cs[bs[2 * si]] == '.'

// Could some path that starts with these segments (and goes deeper) match? Decides which
// directories `walk` opens.
fn can_extend(ps: [Seg], pi: int, cs: [char], bs: [int], si: int): bool {
  if pi == ps.len() { return false }
  if 2 * si == bs.len() { return true }
  match ps[pi] {
    Deep => can_extend(ps, pi + 1, cs, bs, si) ||
      (!hidden(cs, bs, si) && can_extend(ps, pi, cs, bs, si + 1))
    Part(toks) =>
      match_part(toks, cs, bs[2 * si], bs[2 * si + 1]) && can_extend(ps, pi + 1, cs, bs, si + 1)
  }
}

// One segment, `cs[from..to]`, against its tokens: linear-time star backtracking (only the
// last `*` is retried).
fn match_part(toks: [Tok], cs: [char], from: int, to: int): bool {
  let nt = toks.len()
  if to > from && cs[from] == '.' && !(nt > 0 && toks[0] is Lit('.')) { return false }
  var t = 0
  var c = from
  var star_t = -1
  var star_c = 0
  while c < to {
    if t < nt && toks[t] is Star {
      star_t = t
      star_c = c
      t += 1
    } else if t < nt && one(toks[t], cs[c]) {
      t += 1
      c += 1
    } else if star_t >= 0 {
      star_c += 1
      c = star_c
      t = star_t + 1
    } else {
      return false
    }
  }
  while t < nt && toks[t] is Star { t += 1 }
  t == nt
}

fn one(t: Tok, c: char): bool = match t {
  Lit(l) => l == c
  One => true
  Star => true
  Class(neg, rs) => in_class(rs, int(c)) != neg
}

fn in_class(rs: [int], cp: int): bool {
  var i = 0
  while i < rs.len() {
    if cp >= rs[i] && cp <= rs[i + 1] { return true }
    i += 2
  }
  false
}

// ---- parsing ----

// The segments of a pattern without braces: its `/`-separated parts, without empty ones and
// a leading `.`.
fn segs_of(cs: [char]): [Seg] {
  let bs = bounds(cs)
  var out: [Seg] = []
  var j = 0
  while j < bs.len() {
    out.push(seg(cs, bs[j], bs[j + 1]))
    j += 2
  }
  out
}

// The pattern segment `cs[from..to]`.
fn seg(cs: [char], from: int, to: int): Seg {
  if to == from + 2 && cs[from] == '*' && cs[from + 1] == '*' { return Deep }
  var toks: [Tok] = []
  var star = false  // the last token is a Star
  var i = from
  while i < to {
    let c = cs[i]
    if c == '*' {
      if !star { toks.push(Star) }
      star = true
      i += 1
      continue
    }
    star = false
    if c == '\\' && i + 1 < to {
      toks.push(Lit(cs[i + 1]))
      i += 2
    } else if c == '?' {
      toks.push(One)
      i += 1
    } else if c == '[' {
      match class(cs, i, to) {
        some((t, next)) => {
          toks.push(t)
          i = next
        }
        none => {
          toks.push(Lit('['))
          i += 1
        }
      }
    } else {
      toks.push(Lit(c))
      i += 1
    }
  }
  Part(toks)
}

// A `[...]` set starting at cs[at] == '[' in a segment that ends at `to`: the token and the
// index after `]`, or none if the set is never closed.
fn class(cs: [char], at: int, to: int): (Tok, int)? {
  var i = at + 1
  var neg = false
  if i < to && (cs[i] == '!' || cs[i] == '^') {
    neg = true
    i += 1
  }
  var rs: [int] = []
  var first = true
  while i < to {
    var c = cs[i]
    if c == ']' && !first { return some((Class(neg, rs), i + 1)) }
    first = false
    if c == '\\' && i + 1 < to {
      i += 1
      c = cs[i]
    }
    if i + 2 < to && cs[i + 1] == '-' && cs[i + 2] != ']' {
      var hi = cs[i + 2]
      var skip = 3
      if hi == '\\' && i + 3 < to {
        hi = cs[i + 3]
        skip = 4
      }
      rs.push(int(c))
      rs.push(int(hi))
      i += skip
    } else {
      rs.push(int(c))
      rs.push(int(c))
      i += 1
    }
  }
  none
}

// Brace expansion: every alternative spelled out, left to right (`a{b,c}d` -> abd, acd).
// A `{` without a matching `}` and a top-level `,` stays literal, as in bash.
fn expand(p: str): [str] {
  if !p.contains('{') { return [p] }
  expand_chars(p.chars()).map(x => str(x))
}

fn expand_chars(cs: [char]): [[char]] {
  let n = cs.len()
  var i = 0
  while i < n {
    let c = cs[i]
    if c == '\\' {
      i += 2
      continue
    }
    if c == '{' {
      match brace_body(cs, i) {
        some((alts, close)) => {
          let pre = cs[0..i]
          let post = cs[close + 1..n]
          // `pre` holds no expandable braces; `post` and the alternatives are expanded next
          var out: [[char]] = []
          for a in alts { for rest in expand_chars(a + post) { out.push(pre + rest) } }
          return out
        }
        none => {}
      }
    }
    i += 1
  }
  [cs]
}

// The top-level alternatives of the `{...}` opening at cs[at], and the index of its `}`.
fn brace_body(cs: [char], at: int): ([[char]], int)? {
  var depth = 0
  var alts: [[char]] = []
  var from = at + 1  // start of the current alternative
  var i = at + 1
  while i < cs.len() {
    let c = cs[i]
    if c == '\\' && i + 1 < cs.len() {
      i += 2
      continue
    }
    if c == '{' { depth += 1 }
    if c == '}' {
      if depth == 0 {
        if alts.len() == 0 { return none }  // `{a}`: no comma, literal
        alts.push(cs[from..i])
        return some((alts, i))
      }
      depth -= 1
    }
    if c == ',' && depth == 0 {
      alts.push(cs[from..i])
      from = i + 1
    }
    i += 1
  }
  none
}

// ---- tests ----

test "wildcards within a segment" {
  let yes = [
    ("*", "a"),
    ("*", "abc"),
    ("*.auk", "lib.auk"),
    ("*.auk", "a.auk.auk"),
    ("a*", "a"),
    ("*a*b*c*", "xaybzc"),
    ("?", "x"),
    ("??.txt", "ab.txt"),
    ("a?c", "abc"),
    ("*x", "xxxx"),
    ("a*a*a*a*b", "aaaaaaaaaaaaaaaaab"),
    ("日*", "日本"),
    ("?", "本"),
    ("", ""),
    ("**", ""),
    ("abc", "abc"),
  ]
  let no = [
    ("*", ""),
    ("*.auk", "lib.duc"),
    ("?", ""),
    ("?", "ab"),
    ("a?c", "ac"),
    ("abc", "abd"),
    ("*", "a/b"),
    ("a*b", "a/b"),
    ("?", "/"),
    ("a*a*a*a*b", "aaaaaaaaaaaaaaaaaa"),
    ("ABC", "abc"),
    ("*.auk", ".x.auk"),
  ]
  for (p, s) in yes { assert matches(p, s) }
  for (p, s) in no { assert !matches(p, s) }
}

test "character classes" {
  let yes = [
    ("[abc]", "b"),
    ("[a-z]", "q"),
    ("[a-z0-9_]x", "_x"),
    ("[!a]", "b"),
    ("[^a]", "b"),
    ("[]]", "]"),
    ("[]a]", "a"),
    ("[!]]", "x"),
    ("[-a]", "-"),
    ("[a-]", "-"),
    ("[\\]]", "]"),
    ("file[0-9].txt", "file7.txt"),
    ("[[]", "["),
    ("[*?]", "*"),
    ("[α-ω]", "λ"),
  ]
  let no = [
    ("[abc]", "d"),
    ("[a-z]", "A"),
    ("[!a]", "a"),
    ("[^a-c]", "b"),
    ("[a-]", "b"),
    ("[!/]", "/"),
    ("[*]", "x"),
    ("file[0-9].txt", "filex.txt"),
  ]
  for (p, s) in yes { assert matches(p, s) }
  for (p, s) in no { assert !matches(p, s) }
  // an unclosed `[` is a literal
  assert matches("a[b", "a[b") && !matches("a[b", "ab")
}

test "paths and **" {
  let yes = [
    ("src/*.auk", "src/a.auk"),
    ("src/**/*.auk", "src/a.auk"),
    ("src/**/*.auk", "src/x/y/z.auk"),
    ("**/*.auk", "a.auk"),
    ("**/*.auk", "a/b/c.auk"),
    ("**", "a/b/c"),
    ("a/**", "a"),
    ("a/**", "a/b/c"),
    ("a/**/b", "a/b"),
    ("a/**/b", "a/x/y/b"),
    ("**/test/**", "x/test/y"),
    ("*/*", "a/b"),
    ("./src/*.auk", "src/a.auk"),
    ("src/*.auk", "./src/a.auk"),
    ("src//*.auk", "src/a.auk"),
    ("src/", "src"),
    ("/tmp/*", "/tmp/x"),
    ("a/**/**/b", "a/b"),
  ]
  let no = [
    ("src/*.auk", "src/x/a.auk"),
    ("src/*.auk", "lib/a.auk"),
    ("*/*", "a"),
    ("*/*", "a/b/c"),
    ("a/**/b", "a/bc"),
    ("**/*.auk", "a/b.txt"),
    ("/tmp/*", "tmp/x"),
    ("tmp/*", "/tmp/x"),
    ("a/**", "b/a"),
  ]
  for (p, s) in yes { assert matches(p, s) }
  for (p, s) in no { assert !matches(p, s) }
  // `**` inside a longer segment is just `*`
  assert matches("a**b", "axxb") && !matches("a**b", "ax/xb")
}

test "hidden files" {
  assert !matches("*", ".hidden")
  assert !matches("?hidden", ".hidden")
  assert !matches("[.]hidden", ".hidden")
  assert matches(".*", ".hidden") && matches(".h*", ".hidden")
  assert !matches("**/*.auk", ".git/x.auk")
  assert !matches("**/*.auk", "a/.cache/x.auk")
  assert matches("**/.cache/*.auk", "a/.cache/x.auk")
  assert matches(".git/**", ".git/objects/ab")
  assert !matches("*", ".") && !matches("*", "..")
  assert matches("a.*", "a.txt")  // only a leading dot is special
}

test "braces" {
  assert expand(r"a{b,c}d") == ["abd", "acd"]
  assert expand(r"{a,b}{1,2}") == ["a1", "a2", "b1", "b2"]
  assert expand(r"{a,{b,c}x}") == ["a", "bx", "cx"]
  assert expand(r"{,s}") == ["", "s"]
  assert expand(r"{a}") == [r"{a}"]    // no comma: literal
  assert expand(r"{a,b") == [r"{a,b"]  // unclosed: literal
  assert expand(r"\{a,b}") == [r"\{a,b}"]
  assert expand(r"x{a\,b,c}") == ["xa\\,b", "xc"]
  let yes = [
    (r"*.{auk,toml}", "raft.toml"),
    (r"*.{auk,toml}", "lib.auk"),
    (r"{src,lib}/*.auk", "lib/a.auk"),
    (r"{src/**/,}*.auk", "src/x/a.auk"),
    (r"{src/**/,}*.auk", "a.auk"),
    (r"file{,.bak}", "file"),
    (r"file{,.bak}", "file.bak"),
    (r"{a}", r"{a}"),
    (r"x{1,2}{a,b}", "x2a"),
    (r"{[ab],c}", "b"),
  ]
  let no = [(r"*.{auk,toml}", "a.json"), (r"{src,lib}/*.auk", "test/a.auk"), (r"{a}", "a")]
  for (p, s) in yes { assert matches(p, s) }
  for (p, s) in no { assert !matches(p, s) }
}

test "escapes" {
  assert matches("a\\*b", "a*b") && !matches("a\\*b", "axb")
  assert matches("\\?", "?") && !matches("\\?", "x")
  assert matches("\\[x]", "[x]")
  assert matches(r"\{a,b}", r"{a,b}")
  assert escape(r"a*b?[c]{d,e}") == r"a\*b\?\[c\]\{d\,e\}"
  assert escape("\\") == "\\\\"
  for s in ["a*b", "[x]", r"{a,b}", "c:\\dir", "plain.txt", "?"] {
    assert matches(escape(s), s)
    assert !is_pattern(s) || is_pattern(escape(s))
  }
  assert !matches(escape("a*"), "ab")
  assert is_pattern("*.auk") && is_pattern(r"a{b,c}") && !is_pattern("src/lib.auk")
}

test "compiled patterns" {
  let g = compile(r"**/*.{auk,toml}")
  let paths = ["raft.toml", "src/lib.auk", "src/x.rs", ".git/config.toml", "README.md"]
  assert paths.filter(p => matches(g, p)) == ["raft.toml", "src/lib.auk"]
}

test "walk and find in a temp dir" {
  let root = fs.temp_dir()?
  for d in ["src", "src/net", "src/.cache", ".git", "docs", "a.b"] { fs.mkdir("{root}/{d}")? }
  let files = [
    "raft.toml",
    "README.md",
    "src/lib.auk",
    "src/util.auk",
    "src/net/tcp.auk",
    "src/net/notes.txt",
    "src/.cache/old.auk",
    ".git/HEAD",
    "docs/guide.md",
    "a.b/c.auk",
    ".env",
  ]
  for f in files { fs.write("{root}/{f}", "x")? }

  assert walk(root, "**/*.auk")? == ["a.b/c.auk", "src/lib.auk", "src/net/tcp.auk", "src/util.auk"]
  assert walk(root, "src/*.auk")? == ["src/lib.auk", "src/util.auk"]
  assert walk(root, "*")? == ["README.md", "a.b", "docs", "raft.toml", "src"]
  assert walk(root, r"*.{md,toml}")? == ["README.md", "raft.toml"]
  assert walk(root, "src/**")? ==
    ["src", "src/lib.auk", "src/net", "src/net/notes.txt", "src/net/tcp.auk", "src/util.auk"]
  assert walk(root, "**/.cache/*")? == ["src/.cache/old.auk"]
  assert walk(root, ".*")? == [".env", ".git"]
  assert walk(root, ".git/*")? == [".git/HEAD"]
  assert walk(root, "nothing/*.auk")? == []
  assert walk(root + "/", "src/net/*")? == ["src/net/notes.txt", "src/net/tcp.auk"]
  assert walk(root, "src/net/tcp.auk")? == ["src/net/tcp.auk"]
  assert walk("{root}/missing", "*") is err(_)

  // find: the pattern carries its base directory
  assert find("{root}/src/**/*.auk")? ==
    ["{root}/src/lib.auk", "{root}/src/net/tcp.auk", "{root}/src/util.auk"]
  assert find("{root}/*.toml")? == ["{root}/raft.toml"]
  assert find("{root}/raft.toml")? == ["{root}/raft.toml"]
  assert find("{root}/nope.toml")? == []
  assert find("{root}/nope/*.toml")? == []

  // clean up: files, then directories deepest first
  for f in files { fs.remove("{root}/{f}")? }
  for d in ["src/net", "src/.cache", "src", "docs", "a.b", ".git"] { fs.remove("{root}/{d}")? }
  fs.remove(root)?
  assert !fs.exists(root)
}
