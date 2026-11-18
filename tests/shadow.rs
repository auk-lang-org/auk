//! Locals named like modules (card #518), error cascades, and the `??`, `..base` and `for c in s`
//! diagnostics, through `auk check --json` and `auk test`.


use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

mod auk_bin;

fn auk(args: &[&str]) -> Output {
    Command::new(auk_bin::auk_bin()).args(args).output().unwrap()
}

fn scratch() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let dir = std::env::temp_dir().join(format!("auk-shadow-{}-{n}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[derive(Debug, Default)]
struct D {
    code: String,
    severity: String,
    line: u32,
    col: u32,
    message: String,
    notes: Vec<String>,
    /// (line, col, end_line, end_col, text)
    fixes: Vec<(u32, u32, u32, u32, String)>,
}

/// `check --json` on a file: the diagnostics, and whether the exit code was 0.
fn check_path(path: &Path) -> (Vec<D>, bool) {
    let out = auk(&["check", path.to_str().unwrap(), "--json"]);
    let json = String::from_utf8(out.stdout).unwrap();
    let v = Json::parse(&json);
    let ds: Vec<D> = v
        .get("diagnostics")
        .arr()
        .iter()
        .map(|d| D {
            code: d.get("code").str(),
            severity: d.get("severity").str(),
            line: d.get("line").num(),
            col: d.get("col").num(),
            message: d.get("message").str(),
            notes: d.get("notes").arr().iter().map(|n| n.str()).collect(),
            fixes: d
                .get("fixes")
                .arr()
                .iter()
                .map(|f| (f.get("line").num(), f.get("col").num(), f.get("end_line").num(), f.get("end_col").num(), f.get("text").str()))
                .collect(),
        })
        .collect();
    let errors = ds.iter().filter(|d| d.severity == "error").count();
    let ok = matches!(v.get("ok"), Json::Bool(true));
    assert_eq!(ok, errors == 0, "`ok` vs errors: {json}");
    assert_eq!(out.status.success(), errors == 0, "exit status vs errors: {json}");
    (ds, out.status.success())
}

fn check(src: &str) -> Vec<D> {
    let dir = scratch();
    let path = dir.join("t.auk");
    fs::write(&path, src).unwrap();
    let (ds, _) = check_path(&path);
    let _ = fs::remove_dir_all(&dir);
    ds
}

/// The single diagnostic of `src`, with this code and message.
fn one(src: &str, code: &str, message: &str) -> D {
    let mut ds = check(src);
    assert_eq!(ds.len(), 1, "expected exactly one diagnostic for:\n{src}\ngot: {ds:#?}");
    let d = ds.remove(0);
    assert_eq!((d.code.as_str(), d.message.as_str()), (code, message), "{d:#?}");
    d
}

fn clean(src: &str) {
    let ds = check(src);
    assert!(ds.is_empty(), "expected no diagnostics for:\n{src}\ngot: {ds:#?}");
}

fn at(d: &D, line: u32, col: u32) {
    assert_eq!((d.line, d.col), (line, col), "{d:#?}");
}

fn has_note(d: &D, part: &str) {
    assert!(d.notes.iter().any(|n| n.contains(part)), "no note containing {part:?}: {d:#?}");
}

fn fix(d: &D, at: (u32, u32, u32, u32), text: &str) {
    assert!(d.fixes.iter().any(|f| (f.0, f.1, f.2, f.3) == at && f.4 == text), "no fix {at:?} -> {text:?}: {d:#?}");
}

/// Apply several fix-its to `src` (later positions first, so earlier ones stay valid).
fn apply_fixes(src: &str, fixes: &[(u32, u32, u32, u32, String)]) -> String {
    let mut fs: Vec<&(u32, u32, u32, u32, String)> = fixes.iter().collect();
    fs.sort_by_key(|f| std::cmp::Reverse((f.0, f.1)));
    fs.into_iter().fold(src.to_string(), |s, f| apply_fix(&s, f))
}

/// `auk test` on `src`: did every test pass? (and the output)
fn tests_pass(src: &str) -> (bool, String) {
    let dir = scratch();
    let path = dir.join("t.auk");
    fs::write(&path, src).unwrap();
    let out = auk(&["test", path.to_str().unwrap()]);
    let _ = fs::remove_dir_all(&dir);
    (out.status.success(), format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)))
}

/// A project `app` with the given extra files (relative paths) and `src/main.auk`.
fn project(files: &[(&str, &str)], main: &str) -> PathBuf {
    let dir = scratch();
    fs::write(dir.join("raft.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n").unwrap();
    for (p, src) in files {
        let path = dir.join(p);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, src).unwrap();
    }
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::write(dir.join("src/main.auk"), main).unwrap();
    dir
}

const CORE_MODULES: &[&str] = &["env", "fs", "time", "net", "rand", "proc"];

// ---- 1. locals shadow core module names in dot calls ----

/// The bench repros: a parameter named like a core module is the value, not the module.
#[test]
fn bench_repros_resolve_to_the_local() {
    clean("fn f(env: {str: int}, name: str): int? = env.get(name)\nfn main() {}\n");
    clean("fn total(time: [int]): int = time.sum()\nfn main() {}\n");
    // repro 2: no E0410 (and so no `uses env` fix-it), and the call reads the map, not the
    // process environment
    let src = "fn lookup(env: {str: str}, k: str): str? = env.get(k)\ntest \"t\" { assert lookup({\"HOME\": \"x\"}, \"HOME\") == some(\"x\") }\n";
    clean(src);
    let (ok, out) = tests_pass(src);
    assert!(ok, "{out}");
}

/// Every effect module name as a parameter, with methods of lists, maps and strings.
#[test]
fn every_core_module_name_can_be_a_parameter() {
    for m in CORE_MODULES {
        clean(&format!("fn a({m}: {{str: str}}, k: str): str? = {m}.get(k)\nfn main() {{}}\n"));
        clean(&format!("fn b({m}: [int]): int = {m}.len() + {m}.sum()\nfn main() {{}}\n"));
        clean(&format!("fn c({m}: str): [str] = {m}.split(\",\").map(s => s.trim())\nfn main() {{}}\n"));
        clean(&format!("fn d({m}: [int]): int? = {m}.first()\nfn main() {{}}\n"));
        // the value works at run time too, and declaring no effect is right
        let src = format!("fn a({m}: {{str: str}}, k: str): str? = {m}.get(k)\ntest \"t\" {{ assert a({{\"PATH\": \"p\"}}, \"PATH\") == some(\"p\") }}\n");
        let (ok, out) = tests_pass(&src);
        assert!(ok, "{m}: {out}");
    }
}

/// `let`, `var`, `for`, pattern and closure bindings, in nested scopes; the module comes back
/// once the local's scope ends.
#[test]
fn every_kind_of_local_shadows_and_scopes_end() {
    clean("fn f(): int {\n  let fs = [1, 2]\n  fs.len()\n}\nfn main() {}\n");
    clean("fn f(): int {\n  var net = [1]\n  net.push(2)\n  net.len()\n}\nfn main() {}\n");
    clean("fn f(xs: [[int]]): int {\n  var t = 0\n  for rand in xs { t += rand.len() }\n  t\n}\nfn main() {}\n");
    clean("fn f(xs: {str: [int]}): int {\n  var t = 0\n  for k, proc in xs { t += proc.len() + k.len() }\n  t\n}\nfn main() {}\n");
    clean("fn f(p: ([int], int)): int {\n  let (time, n) = p\n  time.len() + n\n}\nfn main() {}\n");
    clean("fn f(o: [int]?): int {\n  match o {\n    some(env) => env.len()\n    none => 0\n  }\n}\nfn main() {}\n");
    clean("fn f(xs: [[int]]): [int] = xs.map(env => env.len())\nfn main() {}\n");
    clean("fn f(xs: [[int]]): [int] = xs.map((fs) => fs.sum())\nfn main() {}\n");
    // a closure capturing an outer local named `time`
    clean("fn f(time: [int], xs: [int]): [int] = xs.map(x => x + time.len())\nfn main() {}\n");
    // nested blocks: the inner local is the value; after its block, `time.now()` is the module
    clean("fn f(): int uses time {\n  if true {\n    let time = [1]\n    print(time.len())\n  }\n  time.now()\n}\nfn main() {}\n");
    let d = one(
        "fn f(): int {\n  if true {\n    let time = [1]\n    print(time.len())\n  }\n  time.now()\n}\nfn main() {}\n",
        "E0410",
        "`f` uses the effect `time` but doesn't declare it",
    );
    at(&d, 6, 3);
}

/// `core.m` always reaches the module, also while a local named `m` is in scope.
#[test]
fn core_prefix_reaches_the_shadowed_module() {
    clean("fn h(env: {str: str}, k: str): int uses env = env.len() + (core.env.get(k) else \"\").len()\nfn main() {}\n");
    clean("fn t(time: [int]): int uses time = time.len() + core.time.now()\nfn main() {}\n");
    clean("fn r(fs: [str]): bool uses fs = fs.all(p => core.fs.exists(p))\nfn main() {}\n");
    // a core call through `core.` still needs its effect, with the usual fix-it
    let d = one("fn h(env: {str: str}, k: str): str? = core.env.get(k)\nfn main() {}\n", "E0410", "`h` uses the effect `env` but doesn't declare it");
    assert_eq!(d.fixes.len(), 1, "{d:#?}");
}

/// The E0410 fix-it is never produced for a call on a local value: with a map parameter `env`,
/// a type error is reported about the map, not a missing effect.
#[test]
fn no_effect_fix_for_a_local() {
    for m in CORE_MODULES {
        let ds = check(&format!("fn f({m}: {{str: int}}, k: str): str? = {m}.get(k)\nfn main() {{}}\n"));
        assert!(!ds.is_empty());
        assert!(ds.iter().all(|d| d.code != "E0410" && d.fixes.iter().all(|f| !f.4.contains("uses"))), "{m}: {ds:#?}");
    }
}

/// A local named like a module of the project, the package itself, a dependency or `core` is
/// an error where it is used as a path (E0116), with no other diagnostic about the call.
#[test]
fn local_named_like_a_project_module_or_dependency_is_an_error() {
    let geo = [("src/geo.auk", "pub fn area(w: int, h: int): int = w * h\npub fn first(xs: [int]): int = 0\n")];
    let dir = project(&geo, "fn f(geo: [int]): int? = geo.first()\nfn main() {}\n");
    let (ds, ok) = check_path(&dir.join("src/main.auk"));
    assert!(!ok);
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!((ds[0].code.as_str(), ds[0].message.as_str()), ("E0116", "`geo` is both a local and the module `app.geo`, so `geo.` is ambiguous"));
    at(&ds[0], 1, 26);
    assert!(ds[0].fixes.is_empty(), "{ds:#?}");
    // the module is fine when no local shadows it, and a local of another name is fine
    let dir = project(&geo, "fn f(g: [int]): int = geo.area(g.len(), 2)\nfn main() {}\n");
    assert!(check_path(&dir.join("src/main.auk")).1);
    // using the local as a plain value (no dot) is fine
    let dir = project(&geo, "fn f(geo: [int]): int = len(geo)\nfn main() {}\n");
    assert!(check_path(&dir.join("src/main.auk")).1, "{:#?}", check_path(&dir.join("src/main.auk")).0);

    // a dependency
    let dep = [
        ("raft.toml", "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[deps]\njson = \"^0.1\"\n"),
        (".raft/json/raft.toml", "[package]\nname = \"json\"\nversion = \"0.1.0\"\n"),
        (".raft/json/src/lib.auk", "pub fn parse(s: str): int = s.len()\n"),
    ];
    let dir = project(&dep, "fn f(json: str): int = json.parse(\"x\")\nfn main() {}\n");
    let (ds, _) = check_path(&dir.join("src/main.auk"));
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!((ds[0].code.as_str(), ds[0].message.as_str()), ("E0116", "`json` is both a local and the dependency `json`, so `json.` is ambiguous"));
    // also in a closure and a field access
    let dir = project(&dep, "fn f(xs: [str]): [int] = xs.map(json => json.len())\nfn main() {}\n");
    let (ds, _) = check_path(&dir.join("src/main.auk"));
    assert_eq!(ds.iter().map(|d| d.code.as_str()).collect::<Vec<_>>(), ["E0116"], "{ds:#?}");
    let dir = project(&dep, "fn main() { print(json.parse(\"ab\")) }\n");
    assert!(check_path(&dir.join("src/main.auk")).1);

    // the package's own name, and `core`
    let dir = project(&[], "fn f(app: [int]): int = app.len()\nfn main() {}\n");
    let (ds, _) = check_path(&dir.join("src/main.auk"));
    assert_eq!(ds.iter().map(|d| d.code.as_str()).collect::<Vec<_>>(), ["E0116"], "{ds:#?}");
    let d = one("fn f(core: [int]): int = core.len()\nfn main() {}\n", "E0116", "`core` is both a local and the core library root, so `core.` is ambiguous");
    at(&d, 1, 26);
}

// ---- 2. no diagnostics caused by `{error}` ----

#[test]
fn error_typed_arguments_cause_no_cascade() {
    // the bench repro: only the E0207 (and the loop variable is a `char`, as after the fix)
    let ds = check("fn f(s: str): int {\n  var t = 0\n  for c in s { t += int(c) }\n  t\n}\nfn main() {}\n");
    assert_eq!(ds.iter().map(|d| d.code.as_str()).collect::<Vec<_>>(), ["E0207"], "{ds:#?}");
    // an `{error}` loop variable passed to an overloaded function
    let ds = check("fn f(n: int): int {\n  var t = 0\n  for c in n { t += int(c) }\n  t\n}\nfn main() {}\n");
    assert_eq!(ds.iter().map(|d| d.code.as_str()).collect::<Vec<_>>(), ["E0207"], "{ds:#?}");
    // an unknown name passed on: one E0102, nothing about `{error}`
    let ds = check("fn f(): int = int(nope) + str(nope).len()\nfn main() {}\n");
    assert!(ds.iter().all(|d| d.code == "E0102"), "{ds:#?}");
    for d in &ds {
        assert!(!d.message.contains("{error}") && d.notes.iter().all(|n| !n.contains("{error}")), "{d:#?}");
    }
}

// ---- 3. `x ?? d` ----

#[test]
fn double_question_with_an_operand_suggests_else() {
    let src = "fn f(m: {str: int}): int {\n  let n = m.get(\"a\") ?? 0\n  n\n}\nfn main() {}\n";
    let d = one(src, "E0039", "`??` is a hole, not a default operator; use `x else 0`");
    at(&d, 2, 22);
    fix(&d, (2, 22, 2, 24), "else");
    clean(&apply_fixes(src, &d.fixes));
    // no spaces
    let src = "fn g(m: {str: str}): str = m.get(\"a\")??\"b\"\nfn main() {}\n";
    let d = one(src, "E0039", "`??` is a hole, not a default operator; use `x else 0`");
    fix(&d, (1, 38, 1, 40), " else ");
    clean(&apply_fixes(src, &d.fixes));
    // a name operand
    let src = "fn h(o: int?, d: int): int = o ?? d\nfn main() {}\n";
    let d = one(src, "E0039", "`??` is a hole, not a default operator; use `x else 0`");
    clean(&apply_fixes(src, &d.fixes));
    // `??` as a hole and `x??` as two `?` are unchanged
    let ds = check("fn f(): int = ??\nfn main() {}\n");
    assert!(ds.iter().all(|d| d.code != "E0039"), "{ds:#?}");
    let ds = check("fn f(x: int?): int? {\n  let y = x??\n  some(y)\n}\nfn main() {}\n");
    assert!(ds.iter().all(|d| d.code.as_str() >= "E0100"), "{ds:#?}");
}

// ---- 4. `..base` not last ----

#[test]
fn struct_base_not_last_gets_a_moving_fix() {
    let acct = "struct Account { id: int, balance: int }\n";
    let src = format!("{acct}fn f(acct: Account, b: int): Account = Account {{ ..acct, balance: b }}\nfn main() {{}}\n");
    let d = one(&src, "E0020", "`..base` must be the last thing in a struct literal");
    at(&d, 2, 58);
    assert_eq!(d.fixes.len(), 2, "{d:#?}");
    let fixed = apply_fixes(&src, &d.fixes);
    assert!(fixed.contains("Account { balance: b, ..acct }"), "{fixed}");
    clean(&fixed);
    // multi-line, several fields after the base, a trailing comma
    let src = format!("{acct}fn g(acct: Account, b: int): Account = Account {{\n  ..acct,\n  balance: b,\n  id: 2,\n}}\nfn main() {{}}\n");
    let d = one(&src, "E0020", "`..base` must be the last thing in a struct literal");
    let fixed = apply_fixes(&src, &d.fixes);
    assert!(fixed.contains("Account {\n  balance: b,\n  id: 2, ..acct,\n}"), "{fixed}");
    clean(&fixed);
    // a base expression that is a call
    let src = format!("{acct}fn mk(): Account = Account {{ id: 1, balance: 0 }}\nfn h(): Account = Account {{ ..mk(), id: 3 }}\nfn main() {{}}\n");
    let d = one(&src, "E0020", "`..base` must be the last thing in a struct literal");
    let fixed = apply_fixes(&src, &d.fixes);
    assert!(fixed.contains("Account { id: 3, ..mk() }"), "{fixed}");
    clean(&fixed);
}

// ---- 5. `for c in s` with `s: str` ----

#[test]
fn looping_over_a_str_suggests_chars() {
    let src = "fn f(s: str): int {\n  var t = 0\n  for c in s { if c.is_digit() { t += 1 } }\n  t\n}\nfn main() {}\n";
    let d = one(src, "E0207", "can't loop over a `str`");
    has_note(&d, "for c in s.chars()");
    fix(&d, (3, 13, 3, 13), ".chars()");
    clean(&apply_fixes(src, &d.fixes));
    // an operator expression gets parentheses
    let src = "fn f(a: str, b: str): int {\n  var t = 0\n  for c in a + b { t += 1 }\n  t\n}\nfn main() {}\n";
    let d = one(src, "E0207", "can't loop over a `str`");
    fix(&d, (3, 12, 3, 17), "(a + b).chars()");
    clean(&apply_fixes(src, &d.fixes));
    // with an index
    let src = "fn f(s: str): int {\n  var t = 0\n  for i, c in s { t += i }\n  t\n}\nfn main() {}\n";
    let d = one(src, "E0207", "can't loop over a `str`");
    clean(&apply_fixes(src, &d.fixes));
}

// ---- a minimal JSON reader for the `check --json` report ----

#[derive(Debug)]
enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    fn parse(s: &str) -> Json {
        let cs: Vec<char> = s.chars().collect();
        let mut i = 0;
        Json::value(&cs, &mut i)
    }

    fn ws(cs: &[char], i: &mut usize) {
        while *i < cs.len() && cs[*i].is_whitespace() {
            *i += 1;
        }
    }

    fn value(cs: &[char], i: &mut usize) -> Json {
        Json::ws(cs, i);
        match cs[*i] {
            '{' => {
                *i += 1;
                let mut kv = Vec::new();
                loop {
                    Json::ws(cs, i);
                    if cs[*i] == '}' {
                        *i += 1;
                        return Json::Obj(kv);
                    }
                    let Json::Str(k) = Json::value(cs, i) else { panic!("key") };
                    Json::ws(cs, i);
                    *i += 1;
                    let v = Json::value(cs, i);
                    kv.push((k, v));
                    Json::ws(cs, i);
                    if cs[*i] == ',' {
                        *i += 1;
                    }
                }
            }
            '[' => {
                *i += 1;
                let mut xs = Vec::new();
                loop {
                    Json::ws(cs, i);
                    if cs[*i] == ']' {
                        *i += 1;
                        return Json::Arr(xs);
                    }
                    xs.push(Json::value(cs, i));
                    Json::ws(cs, i);
                    if cs[*i] == ',' {
                        *i += 1;
                    }
                }
            }
            '"' => {
                *i += 1;
                let mut s = String::new();
                while cs[*i] != '"' {
                    if cs[*i] == '\\' {
                        *i += 1;
                        match cs[*i] {
                            'n' => s.push('\n'),
                            't' => s.push('\t'),
                            'u' => {
                                let h: String = cs[*i + 1..*i + 5].iter().collect();
                                s.push(char::from_u32(u32::from_str_radix(&h, 16).unwrap()).unwrap());
                                *i += 4;
                            }
                            c => s.push(c),
                        }
                    } else {
                        s.push(cs[*i]);
                    }
                    *i += 1;
                }
                *i += 1;
                Json::Str(s)
            }
            't' => {
                *i += 4;
                Json::Bool(true)
            }
            'f' => {
                *i += 5;
                Json::Bool(false)
            }
            'n' => {
                *i += 4;
                Json::Null
            }
            _ => {
                let start = *i;
                while *i < cs.len() && (cs[*i].is_ascii_digit() || "-+.eE".contains(cs[*i])) {
                    *i += 1;
                }
                Json::Num(cs[start..*i].iter().collect::<String>().parse().unwrap())
            }
        }
    }

    fn opt(&self, k: &str) -> Option<&Json> {
        match self {
            Json::Obj(kv) => kv.iter().find(|(x, _)| x == k).map(|(_, v)| v),
            _ => None,
        }
    }

    fn get(&self, k: &str) -> &Json {
        self.opt(k).unwrap_or_else(|| panic!("no key {k} in {self:?}"))
    }

    fn arr(&self) -> &[Json] {
        match self {
            Json::Arr(xs) => xs,
            _ => panic!("not an array: {self:?}"),
        }
    }

    fn str(&self) -> String {
        match self {
            Json::Str(s) => s.clone(),
            _ => panic!("not a string: {self:?}"),
        }
    }

    fn num(&self) -> u32 {
        match self {
            Json::Num(n) => *n as u32,
            _ => panic!("not a number: {self:?}"),
        }
    }
}

/// Apply one fix-it (1-based line/col, end exclusive) to `src`.
fn apply_fix(src: &str, f: &(u32, u32, u32, u32, String)) -> String {
    let offset = |line: u32, col: u32| {
        let start: usize = src.split_inclusive('\n').take(line as usize - 1).map(str::len).sum();
        start + src[start..].chars().take(col as usize - 1).map(char::len_utf8).sum::<usize>()
    };
    let (a, b) = (offset(f.0, f.1), offset(f.2, f.3));
    format!("{}{}{}", &src[..a], f.4, &src[b..])
}
