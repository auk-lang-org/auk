/// tests/parse.rs: the front end via the hidden `auk parse` command: the whole corpus parses,
/// and small programs dump to the expected AST. (The Rust tests always run the Rust `auk`;
/// these skip on a binary that lacks `parse`.)

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("corpus_parses", corpus_parses),
  t.test("ast_snapshots", ast_snapshots),
  t.test("errors_render_with_codes", errors_render_with_codes),
]

fn auk(args: [str]): cmd.Out uses env, ffi, time = t.auk().args(args).output()

/// `examples/*.auk` plus `packages/*/src/*.auk`.
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

/// Write `src` to a scratch file and run `auk parse <args> <file>`.
fn parse_src(args: [str], src: str, tag: str): cmd.Out uses env, fs, ffi, time {
  let dir = t.temp("auk-parse-{tag}")
  let path = paths.join(dir, "t.auk")
  t.write(path, src)
  let out = auk(["parse"] + args + [path])
  t.rm_rf(dir)
  out
}

fn ast(src: str, tag: str): str uses env, fs, ffi, time {
  let out = parse_src(["--ast"], src, tag)
  t.check(out.success(), "parse failed:\n{out.stderr}")
  out.stdout
}

fn corpus_parses() uses env, fs, ffi, time {
  t.skip_if_lacks("parse", "the corpus through `auk parse`")
  let files = corpus()
  t.check(files.len() >= 17, "corpus too small: {files}")
  var failed: [str] = []
  for f in files {
    let out = auk(["parse", f])
    if !out.success() || out.stdout != "ok\n" { failed.push("{f}:\n{out.stderr}") }
  }
  t.check(failed.len() == 0, "{failed.len()} corpus file(s) failed to parse:\n{failed.join("\n")}")
}

fn ast_snapshots() uses env, fs, ffi, time {
  t.skip_if_lacks("parse", "AST snapshots through `auk parse --ast`")
  t.eq(
    ast(
      "fn fib(0): int = 0\nfn fib(1): int = 1\nfn fib(n: int): int = fib(n - 1) + fib(n - 2)\n",
      "1",
    ),
    "(fn fib/1\n  (clause (params 0) : int = 0)\n  (clause (params 1) : int = 1)\n  (clause (params (n: int)) : int = (+ (call fib (- n 1)) (call fib (- n 2)))))\n",
    "fib",
  )
  t.eq(
    ast("struct Point {{ x: float, y: float }}\nlet p = Point {{ x: 1.0, ..o }}\n", "2"),
    "(struct Point (x float) (y float))\n(let p (new Point (x 1.0) (.. o)))\n",
    "struct",
  )
  t.eq(
    ast(
      "fn f(xs: [int]): int! uses fs {{\n  let [h, ..t] = xs else {{ return 0 }}\n  let page = await get(u)?\n  xs\n    |> map(x => x * 2)?\n}}\n",
      "3",
    ),
    "(fn f/1\n  (clause (params (xs: [int])) : int! (uses fs) (block (let (list h (.. t)) xs (else (block (return 0)))) (let page (? (await (call get u)))) (? (|> xs map (closure (x) (* x 2)))))))\n",
    "f",
  )
  t.eq(
    ast(
      "test \"s\" {{\n  assert \"{{n:>5}} {{if a {{ \"x\" }} else {{ \"y\" }}}}\" == \"\"\"\n    ok\n    \"\"\"\n}}\n",
      "4",
    ),
    "(test \"s\" (block (assert (== (str (fmt n \">5\") \" \" (if a (block \"x\") (block \"y\"))) \"ok\\n\"))))\n",
    "test",
  )
  t.eq(
    ast(
      "enum E {{ A(x: int), B }}\nfn g(e: E): int = match e {{\n  A(x) when x > 0 => x, B => 0\n  _ => -1\n}}\n",
      "5",
    ),
    "(enum E (A (x int)) B)\n(fn g/1\n  (clause (params (e: E)) : int = (match e ((A x) when (> x 0) => x) (B => 0) (_ => (- 1)))))\n",
    "enum",
  )
  // `?.N` (a tuple element) composes like `.N`
  t.eq(
    ast("fn f() = xs.first()?.1?.len()\n", "6"),
    "(fn f/0\n  (clause (params) = (?. (?. (method xs first) 1) len (args))))\n",
    "?.N",
  )
}

fn errors_render_with_codes() uses env, fs, ffi, time {
  t.skip_if_lacks("parse", "parse errors through `auk parse`")
  let out = parse_src([], "fn main() {{\n  let x = 1;\n}}\n", "e1")
  assert !out.success()
  let err = out.stderr
  t.check(err.contains(":2:12: error[E0011]: Auk does not use semicolons\n"), err)
  t.check(err.contains("2 |   let x = 1;\n  |"), err)
  t.check(err.contains("           ^\n"), err)

  let out = parse_src(["--json"], "fn f() -> int = 1\n", "e2")
  assert !out.success()
  let js = out.stdout
  t.check(
    js.contains("\"ok\":false,\"diagnostics\":[{{\"code\":\"E0035\",\"severity\":\"error\",\"line\":1,\"col\":8,\"end_line\":1,\"end_col\":10,"),
    js,
  )
  t.check(
    js.contains("\"fixes\":[{{\"line\":1,\"col\":8,\"end_line\":1,\"end_col\":10,\"text\":\":\"}}]"),
    js,
  )

  let out = parse_src(["--json"], "fn f() = 1\n", "e3")
  assert out.success()
  t.check(out.stdout.contains("\"ok\":true,\"diagnostics\":[]"), out.stdout)
}
