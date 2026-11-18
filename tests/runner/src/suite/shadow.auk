/// tests/shadow.rs: locals named like modules (card #518), error cascades, and the `??`,
/// `..base` and `for c in s` diagnostics, through `auk check --json` and `auk test`.
///
/// The Rust file reads the `check --json` report with a minimal JSON reader of its own; this
/// port reads it with json.auk (the same values).

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("bench_repros_resolve_to_the_local", bench_repros_resolve_to_the_local),
  t.test("every_core_module_name_can_be_a_parameter", every_core_module_name_can_be_a_parameter),
  t.test("every_kind_of_local_shadows_and_scopes_end", every_kind_of_local_shadows_and_scopes_end),
  t.test("core_prefix_reaches_the_shadowed_module", core_prefix_reaches_the_shadowed_module),
  t.test("no_effect_fix_for_a_local", no_effect_fix_for_a_local),
  t.test(
    "local_named_like_a_project_module_or_dependency_is_an_error",
    local_named_like_a_project_module_or_dependency_is_an_error,
  ),
  t.test("error_typed_arguments_cause_no_cascade", error_typed_arguments_cause_no_cascade),
  t.test(
    "double_question_with_an_operand_suggests_else",
    double_question_with_an_operand_suggests_else,
  ),
  t.test("struct_base_not_last_gets_a_moving_fix", struct_base_not_last_gets_a_moving_fix),
  t.test("looping_over_a_str_suggests_chars", looping_over_a_str_suggests_chars),
]

extern fn c_mkdtemp(t: ffi.Ptr): ffi.Ptr? = "char *mkdtemp(char *)"

/// A fresh, unique directory under the system's temporary directory (Rust's numbered
/// `auk-shadow-<pid>-<n>`).
fn scratch(): str uses fs, ffi {
  let base = fs.temp_dir() else "/tmp"
  let tpl = paths.join(base.strip_suffix("/") else base, "auk-shadow-{sys.pid()}-XXXXXX")
  let p = ffi.from_bytes(tpl.bytes() + [0])
  let r = c_mkdtemp(p)
  let d = ffi.cstr(p)
  ffi.free(p)
  if r is none { t.fail("mkdtemp {tpl} failed") }
  d
}

struct D {
  code: str,
  severity: str,
  line: int,
  col: int,
  message: str,
  notes: [str],
  /// (line, col, end_line, end_col, text)
  fixes: [(int, int, int, int, str)],
}

fn jstr(j: json.Json): str = j.as_str() else t.bail("not a string: {j.text()}")

fn jnum(j: json.Json): int = j.as_i64() else t.bail("not a number: {j.text()}")

/// `check --json` on a file: the diagnostics, and whether the exit code was 0.
fn check_path(path: str): ([D], bool) uses env, ffi, time {
  let out = t.auk().args(["check", path, "--json"]).output()
  let text = out.stdout
  let v = match json.parse(text) {
    ok(v) => v
    err(Bad(e)) => t.bail("not JSON ({e}): {text}")
  }
  let ds = v.get("diagnostics").as_arr().map(d => D {
    code: jstr(d.get("code")),
    severity: jstr(d.get("severity")),
    line: jnum(d.get("line")),
    col: jnum(d.get("col")),
    message: jstr(d.get("message")),
    notes: d.get("notes").as_arr().map(n => jstr(n)),
    fixes: d
      .get("fixes")
      .as_arr()
      .map(
        f => (
          jnum(f.get("line")),
          jnum(f.get("col")),
          jnum(f.get("end_line")),
          jnum(f.get("end_col")),
          jstr(f.get("text")),
        ),
      ),
  })
  let errors = ds.filter(d => d.severity == "error").len()
  let ok = v.get("ok") == json.Json.Bool(true)
  t.check(ok == (errors == 0), "`ok` vs errors: {text}")
  t.check(out.success() == (errors == 0), "exit status vs errors: {text}")
  (ds, out.success())
}

fn check(src: str): [D] uses env, fs, ffi, time {
  let dir = scratch()
  let path = paths.join(dir, "t.auk")
  t.write(path, src)
  let (ds, _) = check_path(path)
  t.rm_rf(dir)
  ds
}

/// The single diagnostic of `src`, with this code and message.
fn one(src: str, code: str, message: str): D uses env, fs, ffi, time {
  let ds = check(src)
  t.check(ds.len() == 1, "expected exactly one diagnostic for:\n{src}\ngot: {ds}")
  let d = ds[0]
  t.check((d.code, d.message) == (code, message), "{d}")
  d
}

fn clean(src: str) uses env, fs, ffi, time {
  let ds = check(src)
  t.check(ds.len() == 0, "expected no diagnostics for:\n{src}\ngot: {ds}")
}

fn at(d: D, line: int, col: int) { t.check((d.line, d.col) == (line, col), "{d}") }

fn has_note(d: D, part: str) {
  t.check(d.notes.any(n => n.contains(part)), "no note containing {part.show()}: {d}")
}

fn fix(d: D, at: (int, int, int, int), text: str) {
  t.check(
    d.fixes.any(f => (f.0, f.1, f.2, f.3) == at && f.4 == text),
    "no fix {at} -> {text.show()}: {d}",
  )
}

/// Apply several fix-its to `src` (later positions first, so earlier ones stay valid).
fn apply_fixes(src: str, fixes: [(int, int, int, int, str)]): str {
  fixes.sort_by(f => (-f.0, -f.1)).reduce(src, (s, f) => apply_fix(s, f))
}

/// Apply one fix-it (1-based line/col, end exclusive) to `src`.
fn apply_fix(src: str, f: (int, int, int, int, str)): str {
  let offset = (line: int, col: int) => {
    let parts = src.split("\n")
    var start = 0
    for i in 0..min(line - 1, parts.len()) {
      start += parts[i].len() + if i < parts.len() - 1 { 1 } else { 0 }
    }
    start + min(col - 1, src.len() - start)
  }
  let (a, b) = (offset(f.0, f.1), offset(f.2, f.3))
  src[0..a] + f.4 + src[b..src.len()]
}

/// `auk test` on `src`: did every test pass? (and the output)
fn tests_pass(src: str): (bool, str) uses env, fs, ffi, time {
  let dir = scratch()
  let path = paths.join(dir, "t.auk")
  t.write(path, src)
  let out = t.auk().args(["test", path]).output()
  t.rm_rf(dir)
  (out.success(), out.stdout + out.stderr)
}

/// A project `app` with the given extra files (relative paths) and `src/main.auk`.
fn project(files: [(str, str)], main: str): str uses fs, ffi {
  let dir = scratch()
  t.write(paths.join(dir, "raft.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n")
  for (p, src) in files { t.write(paths.join(dir, p), src) }
  t.write(paths.join(dir, "src/main.auk"), main)
  dir
}

let CORE_MODULES = ["env", "fs", "time", "net", "rand", "proc"]

// ---- 1. locals shadow core module names in dot calls ----

/// The bench repros: a parameter named like a core module is the value, not the module.
fn bench_repros_resolve_to_the_local() uses env, fs, ffi, time {
  clean("fn f(env: {{str: int}}, name: str): int? = env.get(name)\nfn main() {{}}\n")
  clean("fn total(time: [int]): int = time.sum()\nfn main() {{}}\n")
  // repro 2: no E0410 (and so no `uses env` fix-it), and the call reads the map, not the
  // process environment
  let src = "fn lookup(env: {{str: str}}, k: str): str? = env.get(k)\ntest \"t\" {{ assert lookup({{\"HOME\": \"x\"}}, \"HOME\") == some(\"x\") }}\n"
  clean(src)
  let (ok, out) = tests_pass(src)
  t.check(ok, out)
}

/// Every effect module name as a parameter, with methods of lists, maps and strings.
fn every_core_module_name_can_be_a_parameter() uses env, fs, ffi, time {
  for m in CORE_MODULES {
    clean("fn a({m}: {{str: str}}, k: str): str? = {m}.get(k)\nfn main() {{}}\n")
    clean("fn b({m}: [int]): int = {m}.len() + {m}.sum()\nfn main() {{}}\n")
    clean("fn c({m}: str): [str] = {m}.split(\",\").map(s => s.trim())\nfn main() {{}}\n")
    clean("fn d({m}: [int]): int? = {m}.first()\nfn main() {{}}\n")
    // the value works at run time too, and declaring no effect is right
    let src = "fn a({m}: {{str: str}}, k: str): str? = {m}.get(k)\ntest \"t\" {{ assert a({{\"PATH\": \"p\"}}, \"PATH\") == some(\"p\") }}\n"
    let (ok, out) = tests_pass(src)
    t.check(ok, "{m}: {out}")
  }
}

/// `let`, `var`, `for`, pattern and closure bindings, in nested scopes; the module comes back
/// once the local's scope ends.
fn every_kind_of_local_shadows_and_scopes_end() uses env, fs, ffi, time {
  clean("fn f(): int {{\n  let fs = [1, 2]\n  fs.len()\n}}\nfn main() {{}}\n")
  clean("fn f(): int {{\n  var net = [1]\n  net.push(2)\n  net.len()\n}}\nfn main() {{}}\n")
  clean("fn f(xs: [[int]]): int {{\n  var t = 0\n  for rand in xs {{ t += rand.len() }}\n  t\n}}\nfn main() {{}}\n")
  clean("fn f(xs: {{str: [int]}}): int {{\n  var t = 0\n  for k, proc in xs {{ t += proc.len() + k.len() }}\n  t\n}}\nfn main() {{}}\n")
  clean("fn f(p: ([int], int)): int {{\n  let (time, n) = p\n  time.len() + n\n}}\nfn main() {{}}\n")
  clean("fn f(o: [int]?): int {{\n  match o {{\n    some(env) => env.len()\n    none => 0\n  }}\n}}\nfn main() {{}}\n")
  clean("fn f(xs: [[int]]): [int] = xs.map(env => env.len())\nfn main() {{}}\n")
  clean("fn f(xs: [[int]]): [int] = xs.map((fs) => fs.sum())\nfn main() {{}}\n")
  // a closure capturing an outer local named `time`
  clean("fn f(time: [int], xs: [int]): [int] = xs.map(x => x + time.len())\nfn main() {{}}\n")
  // nested blocks: the inner local is the value; after its block, `time.now()` is the module
  clean("fn f(): int uses time {{\n  if true {{\n    let time = [1]\n    print(time.len())\n  }}\n  time.now()\n}}\nfn main() {{}}\n")
  let d = one(
    "fn f(): int {{\n  if true {{\n    let time = [1]\n    print(time.len())\n  }}\n  time.now()\n}}\nfn main() {{}}\n",
    "E0410",
    "`f` uses the effect `time` but doesn't declare it",
  )
  at(d, 6, 3)
}

/// `core.m` always reaches the module, also while a local named `m` is in scope.
fn core_prefix_reaches_the_shadowed_module() uses env, fs, ffi, time {
  clean("fn h(env: {{str: str}}, k: str): int uses env = env.len() + (core.env.get(k) else \"\").len()\nfn main() {{}}\n")
  clean("fn t(time: [int]): int uses time = time.len() + core.time.now()\nfn main() {{}}\n")
  clean("fn r(fs: [str]): bool uses fs = fs.all(p => core.fs.exists(p))\nfn main() {{}}\n")
  // a core call through `core.` still needs its effect, with the usual fix-it
  let d = one(
    "fn h(env: {{str: str}}, k: str): str? = core.env.get(k)\nfn main() {{}}\n",
    "E0410",
    "`h` uses the effect `env` but doesn't declare it",
  )
  t.check(d.fixes.len() == 1, "{d}")
}

/// The E0410 fix-it is never produced for a call on a local value: with a map parameter `env`,
/// a type error is reported about the map, not a missing effect.
fn no_effect_fix_for_a_local() uses env, fs, ffi, time {
  for m in CORE_MODULES {
    let ds = check("fn f({m}: {{str: int}}, k: str): str? = {m}.get(k)\nfn main() {{}}\n")
    assert ds.len() > 0
    t.check(ds.all(d => d.code != "E0410" && d.fixes.all(f => !f.4.contains("uses"))), "{m}: {ds}")
  }
}

/// A local named like a module of the project, the package itself, a dependency or `core` is
/// an error where it is used as a path (E0116), with no other diagnostic about the call.
fn local_named_like_a_project_module_or_dependency_is_an_error() uses env, fs, ffi, time {
  let geo = [
    ("src/geo.auk", "pub fn area(w: int, h: int): int = w * h\npub fn first(xs: [int]): int = 0\n"),
  ]
  let dir = project(geo, "fn f(geo: [int]): int? = geo.first()\nfn main() {{}}\n")
  let main = (d: str) => paths.join(d, "src/main.auk")
  let (ds, ok) = check_path(main(dir))
  assert !ok
  t.check(ds.len() == 1, "{ds}")
  t.check(
    (ds[0].code, ds[0].message) ==
      ("E0116", "`geo` is both a local and the module `app.geo`, so `geo.` is ambiguous"),
    "{ds}",
  )
  at(ds[0], 1, 26)
  t.check(ds[0].fixes.len() == 0, "{ds}")
  // the module is fine when no local shadows it, and a local of another name is fine
  let dir = project(geo, "fn f(g: [int]): int = geo.area(g.len(), 2)\nfn main() {{}}\n")
  assert check_path(main(dir)).1
  // using the local as a plain value (no dot) is fine
  let dir = project(geo, "fn f(geo: [int]): int = len(geo)\nfn main() {{}}\n")
  t.check(check_path(main(dir)).1, "{check_path(main(dir)).0}")

  // a dependency
  let dep = [
    ("raft.toml", "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[deps]\njson = \"^0.1\"\n"),
    (".raft/json/raft.toml", "[package]\nname = \"json\"\nversion = \"0.1.0\"\n"),
    (".raft/json/src/lib.auk", "pub fn parse(s: str): int = s.len()\n"),
  ]
  let dir = project(dep, "fn f(json: str): int = json.parse(\"x\")\nfn main() {{}}\n")
  let (ds, _) = check_path(main(dir))
  t.check(ds.len() == 1, "{ds}")
  t.check(
    (ds[0].code, ds[0].message) ==
      ("E0116", "`json` is both a local and the dependency `json`, so `json.` is ambiguous"),
    "{ds}",
  )
  // also in a closure and a field access
  let dir = project(dep, "fn f(xs: [str]): [int] = xs.map(json => json.len())\nfn main() {{}}\n")
  let (ds, _) = check_path(main(dir))
  t.check(ds.map(d => d.code) == ["E0116"], "{ds}")
  let dir = project(dep, "fn main() {{ print(json.parse(\"ab\")) }}\n")
  assert check_path(main(dir)).1

  // the package's own name, and `core`
  let dir = project([], "fn f(app: [int]): int = app.len()\nfn main() {{}}\n")
  let (ds, _) = check_path(main(dir))
  t.check(ds.map(d => d.code) == ["E0116"], "{ds}")
  let d = one(
    "fn f(core: [int]): int = core.len()\nfn main() {{}}\n",
    "E0116",
    "`core` is both a local and the core library root, so `core.` is ambiguous",
  )
  at(d, 1, 26)
}

// ---- 2. no diagnostics caused by `{error}` ----

fn error_typed_arguments_cause_no_cascade() uses env, fs, ffi, time {
  // the bench repro: only the E0207 (and the loop variable is a `char`, as after the fix)
  let ds = check("fn f(s: str): int {{\n  var t = 0\n  for c in s {{ t += int(c) }}\n  t\n}}\nfn main() {{}}\n")
  t.check(ds.map(d => d.code) == ["E0207"], "{ds}")
  // an `{error}` loop variable passed to an overloaded function
  let ds = check("fn f(n: int): int {{\n  var t = 0\n  for c in n {{ t += int(c) }}\n  t\n}}\nfn main() {{}}\n")
  t.check(ds.map(d => d.code) == ["E0207"], "{ds}")
  // an unknown name passed on: one E0102, nothing about `{error}`
  let ds = check("fn f(): int = int(nope) + str(nope).len()\nfn main() {{}}\n")
  t.check(ds.all(d => d.code == "E0102"), "{ds}")
  for d in ds {
    t.check(!d.message.contains("{{error}}") && d.notes.all(n => !n.contains("{{error}}")), "{d}")
  }
}

// ---- 3. `x ?? d` ----

fn double_question_with_an_operand_suggests_else() uses env, fs, ffi, time {
  let src = "fn f(m: {{str: int}}): int {{\n  let n = m.get(\"a\") ?? 0\n  n\n}}\nfn main() {{}}\n"
  let d = one(src, "E0039", "`??` is a hole, not a default operator; use `x else 0`")
  at(d, 2, 22)
  fix(d, (2, 22, 2, 24), "else")
  clean(apply_fixes(src, d.fixes))
  // no spaces
  let src = "fn g(m: {{str: str}}): str = m.get(\"a\")??\"b\"\nfn main() {{}}\n"
  let d = one(src, "E0039", "`??` is a hole, not a default operator; use `x else 0`")
  fix(d, (1, 38, 1, 40), " else ")
  clean(apply_fixes(src, d.fixes))
  // a name operand
  let src = "fn h(o: int?, d: int): int = o ?? d\nfn main() {{}}\n"
  let d = one(src, "E0039", "`??` is a hole, not a default operator; use `x else 0`")
  clean(apply_fixes(src, d.fixes))
  // `??` as a hole and `x??` as two `?` are unchanged
  let ds = check("fn f(): int = ??\nfn main() {{}}\n")
  t.check(ds.all(d => d.code != "E0039"), "{ds}")
  let ds = check("fn f(x: int?): int? {{\n  let y = x??\n  some(y)\n}}\nfn main() {{}}\n")
  t.check(ds.all(d => d.code >= "E0100"), "{ds}")
}

// ---- 4. `..base` not last ----

fn struct_base_not_last_gets_a_moving_fix() uses env, fs, ffi, time {
  let acct = "struct Account {{ id: int, balance: int }}\n"
  let src = "{acct}fn f(acct: Account, b: int): Account = Account {{ ..acct, balance: b }}\nfn main() {{}}\n"
  let d = one(src, "E0020", "`..base` must be the last thing in a struct literal")
  at(d, 2, 58)
  t.check(d.fixes.len() == 2, "{d}")
  let fixed = apply_fixes(src, d.fixes)
  t.check(fixed.contains("Account {{ balance: b, ..acct }}"), fixed)
  clean(fixed)
  // multi-line, several fields after the base, a trailing comma
  let src = "{acct}fn g(acct: Account, b: int): Account = Account {{\n  ..acct,\n  balance: b,\n  id: 2,\n}}\nfn main() {{}}\n"
  let d = one(src, "E0020", "`..base` must be the last thing in a struct literal")
  let fixed = apply_fixes(src, d.fixes)
  t.check(fixed.contains("Account {{\n  balance: b,\n  id: 2, ..acct,\n}}"), fixed)
  clean(fixed)
  // a base expression that is a call
  let src = "{acct}fn mk(): Account = Account {{ id: 1, balance: 0 }}\nfn h(): Account = Account {{ ..mk(), id: 3 }}\nfn main() {{}}\n"
  let d = one(src, "E0020", "`..base` must be the last thing in a struct literal")
  let fixed = apply_fixes(src, d.fixes)
  t.check(fixed.contains("Account {{ id: 3, ..mk() }}"), fixed)
  clean(fixed)
}

// ---- 5. `for c in s` with `s: str` ----

fn looping_over_a_str_suggests_chars() uses env, fs, ffi, time {
  let src = "fn f(s: str): int {{\n  var t = 0\n  for c in s {{ if c.is_digit() {{ t += 1 }} }}\n  t\n}}\nfn main() {{}}\n"
  let d = one(src, "E0207", "can't loop over a `str`")
  has_note(d, "for c in s.chars()")
  fix(d, (3, 13, 3, 13), ".chars()")
  clean(apply_fixes(src, d.fixes))
  // an operator expression gets parentheses
  let src = "fn f(a: str, b: str): int {{\n  var t = 0\n  for c in a + b {{ t += 1 }}\n  t\n}}\nfn main() {{}}\n"
  let d = one(src, "E0207", "can't loop over a `str`")
  fix(d, (3, 12, 3, 17), "(a + b).chars()")
  clean(apply_fixes(src, d.fixes))
  // with an index
  let src =
    "fn f(s: str): int {{\n  var t = 0\n  for i, c in s {{ t += i }}\n  t\n}}\nfn main() {{}}\n"
  let d = one(src, "E0207", "can't loop over a `str`")
  clean(apply_fixes(src, d.fixes))
}
