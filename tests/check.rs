//! The checker through `auk check`: the whole corpus checks clean (and its typed program
//! satisfies codegen's invariants), and small programs get the exact diagnostic codes,
//! messages and fix-its.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::Once;
use std::sync::atomic::{AtomicUsize, Ordering};

mod auk_bin;

fn auk(args: &[&str]) -> Output {
    Command::new(auk_bin::auk_bin()).args(args).output().unwrap()
}

/// `raft install` in `dir`; a lock that no longer matches the registry (the in-repo packages are
/// edited freely) is regenerated.
fn install(dir: &str) {
    let run = || Command::new(env!("CARGO_BIN_EXE_raft")).arg("install").current_dir(dir).output().unwrap();
    let out = run();
    if !out.status.success() {
        let _ = fs::remove_file(Path::new(dir).join("raft.lock"));
        let _ = fs::remove_dir_all(Path::new(dir).join(".raft"));
        let out = run();
        assert!(out.status.success(), "raft install in {dir} failed:\n{}", String::from_utf8_lossy(&out.stderr));
    }
}

/// Install the dependencies of the example project and of the packages that have any.
fn setup() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        install("examples");
        install("packages/http");
        install("packages/url");
        install("packages/log");
    });
}

fn auk_files(dir: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "auk")).collect();
    paths.sort();
    paths
}

/// Every example program, and every package checked from its root module.
fn corpus_roots() -> Vec<PathBuf> {
    let mut files = auk_files(Path::new("examples"));
    let mut pkgs: Vec<_> = fs::read_dir("packages").unwrap().map(|e| e.unwrap().path().join("src/lib.auk")).filter(|p| p.is_file()).collect();
    pkgs.sort();
    files.extend(pkgs);
    files
}

#[test]
fn corpus_checks_clean() {
    setup();
    let files = corpus_roots();
    assert!(files.len() >= 15, "corpus too small: {files:?}");
    let mut failed = Vec::new();
    for f in &files {
        let p = f.to_str().unwrap();
        let out = auk(&["check", p, "--json"]);
        let json = String::from_utf8_lossy(&out.stdout).to_string();
        if !out.status.success() || !json.contains(r#""ok":true,"diagnostics":[]"#) {
            let text = String::from_utf8_lossy(&auk(&["check", p]).stderr).to_string();
            failed.push(format!("{p}:\n{text}"));
        }
    }
    assert!(failed.is_empty(), "{} corpus file(s) failed to check:\n{}", failed.len(), failed.join("\n"));
}

/// The typed program of every corpus root has no inference variables or error types left, and
/// every generic instance is concrete (`auk typed` runs `TypedProgram::validate`).
#[test]
fn corpus_typed_invariants() {
    if auk_bin::lacks("typed", "the typed program and its invariants") {
        return;
    }
    setup();
    for f in corpus_roots() {
        let p = f.to_str().unwrap();
        let out = auk(&["typed", p]);
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success() && !text.contains("INVARIANT"), "{p}:\n{text}{}", String::from_utf8_lossy(&out.stderr));
        assert!(text.contains(" instances, "), "{p}: {text}");
    }
}

#[test]
fn shapes_monomorphize_per_type() {
    if auk_bin::lacks("typed", "the generic instances") {
        return;
    }
    setup();
    let out = auk(&["typed", "examples/inventory.auk"]);
    let text = String::from_utf8_lossy(&out.stdout);
    // (core's own generics instantiate too; `sort` is a runtime extern, so `filter` stands for them)
    for want in ["examples.top<Item>", "examples.report<Item>", "examples.report<Order>", "core.filter<int>"] {
        assert!(text.contains(want), "missing instance {want}:\n{text}");
    }
    assert!(text.contains("fn examples.top<Ord>([Ord], int): [Ord]"), "{text}");
}

// ---- small programs ----

/// A fresh directory for one test program (no raft.toml, so core only).
fn scratch() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let dir = std::env::temp_dir().join(format!("auk-check-{}-{n}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// One diagnostic from `check --json`.
#[derive(Debug, Default)]
struct D {
    code: String,
    line: u32,
    col: u32,
    message: String,
    notes: Vec<String>,
    /// (line, col, end_line, end_col, text)
    fixes: Vec<(u32, u32, u32, u32, String)>,
}

/// Check `src` as a standalone file; the diagnostics in order.
fn check(src: &str) -> Vec<D> {
    let dir = scratch();
    let path = dir.join("t.auk");
    fs::write(&path, src).unwrap();
    let ds = check_path(&path);
    let _ = fs::remove_dir_all(&dir);
    ds
}

fn check_path(path: &Path) -> Vec<D> {
    let out = auk(&["check", path.to_str().unwrap(), "--json"]);
    let json = String::from_utf8(out.stdout).unwrap();
    let v = Json::parse(&json);
    let ds = v.get("diagnostics").arr();
    // warnings (severity "warning") don't fail the check
    let errors = ds.iter().filter(|d| d.get("severity").str() != "warning").count();
    assert_eq!(out.status.success(), errors == 0, "exit status vs diagnostics: {json}");
    ds.iter()
        .map(|d| D {
            code: d.get("code").str(),
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
        .collect()
}

/// The single diagnostic of `src`, which must have this code and message.
fn one(src: &str, code: &str, message: &str) -> D {
    let mut ds = check(src);
    assert_eq!(ds.len(), 1, "expected exactly one diagnostic for:\n{src}\ngot: {ds:#?}");
    let d = ds.remove(0);
    assert_eq!((d.code.as_str(), d.message.as_str()), (code, message), "{d:#?}");
    d
}

fn has_note(d: &D, part: &str) {
    assert!(d.notes.iter().any(|n| n.contains(part)), "no note containing {part:?}: {d:#?}");
}

fn fix(d: &D, at: (u32, u32, u32, u32), text: &str) {
    assert!(d.fixes.iter().any(|f| (f.0, f.1, f.2, f.3) == at && f.4 == text), "no fix {at:?} -> {text:?}: {d:#?}");
}

/// A minimal JSON reader for the `check --json` report.
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
                    *i += 1; // :
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
                while *i < cs.len() && (cs[*i].is_ascii_digit() || cs[*i] == '-' || cs[*i] == '.') {
                    *i += 1;
                }
                Json::Num(cs[start..*i].iter().collect::<String>().parse().unwrap())
            }
        }
    }

    fn get(&self, k: &str) -> &Json {
        match self {
            Json::Obj(kv) => kv.iter().find(|(x, _)| x == k).map(|(_, v)| v).unwrap_or(&Json::Null),
            _ => &Json::Null,
        }
    }

    fn arr(&self) -> &[Json] {
        match self {
            Json::Arr(xs) => xs,
            _ => &[],
        }
    }

    fn str(&self) -> String {
        match self {
            Json::Str(s) => s.clone(),
            Json::Bool(b) => b.to_string(),
            _ => String::new(),
        }
    }

    fn num(&self) -> u32 {
        match self {
            Json::Num(n) => *n as u32,
            _ => 0,
        }
    }
}

// ---- positive programs: every feature the checker covers ----

#[test]
fn feature_programs_check_clean() {
    for (name, src) in [("features", FEATURES), ("spec examples", SPEC_EXAMPLES), ("generics", GENERICS)] {
        let ds = check(src);
        assert!(ds.is_empty(), "{name}: {ds:#?}");
    }
}

const FEATURES: &str = r#"
shape Area { fn area(self): float }
struct Circle { r: float }
struct Sq { s: float }
fn area(c: Circle): float = 3.14 * c.r * c.r
fn area(s: Sq): float = s.s * s.s
fn total(xs: [Area]): float = xs.map(x => x.area()).sum()
fn draw(xs: [any Area]): float {
  var t = 0.0
  for x in xs { t += x.area() }
  t
}
fn biggest(a: Ord, b: Ord): Ord = if a > b { a } else { b }
fn pair<A: Show, B: Show>(a: A, b: B): str = a.show() + b.show()
struct V { x: int, y: int }
fn add(a: V, b: V): V = V { x: a.x + b.x, y: a.y + b.y }
enum Tree { Leaf, Node(l: Tree, v: int, r: Tree) }
fn sum(Leaf): int = 0
fn sum(Node(l, v, r)): int = sum(l) + v + sum(r)
fn push2(xs: var [int], v: int) { xs.push(v) }
async fn get(n: int): int! { n }
fn opt(n: int): int? = if n > 0 { n } else { none }
fn twice(f: (int) => int, x: int): int = f(f(x))
let LIMIT = 10
imprint TABLE = [1, 2, 3].map(x => x * x)
fn fail_with(n: int): int! {
  if n > 0 { fail("bad {n}") }
  n
}
test "features" {
  assert total([Circle { r: 1.0 }, Circle { r: 2.0 }]) > 0.0
  assert draw([Circle { r: 1.0 }, Sq { s: 2.0 }]) > 0.0
  assert biggest(3, 4) == 4 && biggest("a", "b") == "b"
  assert pair(1, "x") == "1x"
  assert V { x: 1, y: 2 } + V { x: 3, y: 4 } == V { x: 4, y: 6 }
  assert sum(Node(Leaf, 3, Node(Leaf, 4, Leaf))) == 7
  var xs = [1]
  push2(&xs, 2)
  xs.push2(3)
  let (a, b) = await (get(1), get(2))
  assert a? + b? == 3
  let all = await [1, 2, 3].map(n => get(n))
  assert all.len() == 3
  let t = get(5)
  assert (await t)? == 5
  assert opt(3)?.show() is some(_)
  assert (opt(-1) else 0) == 0
  assert twice(x => x + 1, LIMIT) == 12
  assert TABLE[2] == 9
  assert peek xs.len() * 2 == 6
  let s: Set<int> = set([1, 2, 2])
  assert s.len() == 2
  for k, v in {"a": 1} { assert k.len() == v }
  assert {"a": 1}.entries()[0] == ("a", 1)
  assert xs.enum().map((i, x) => i + x)[0] == 1
  assert xs.max()! == 3
  let z = xs.find(x => x > 1) else return
  assert z == 2
  let e: int! = fail_with(1)
  let msg = match e { ok(n) => "{n}", err(er) => "{er}" }
  assert msg.len() > 0 && e is err(_)
  assert int('a') == 97 && char(97)! == 'a'
  assert "{3.14159:.2} {42:>5} {"x":<3}|" == "3.14    42 x  |"
  assert [3, 1, 2].sort() == [1, 2, 3] && [[1], [2]] == [[1], [2]] && (1, "a") < (2, "b")
  assert str(['a', 'b']) == "ab"
  match e { ok(_) => {}, err(_) => {} }
}
"#;

const GENERICS: &str = r#"
struct Box<T> { v: T }
enum Tree<T> { Leaf, Node(l: Tree<T>, v: T, r: Tree<T>) }
fn insert<T: Ord>(t: Tree<T>, x: T): Tree<T> = match t {
  Leaf => Node(Leaf, x, Leaf)
  Node(l, v, r) when x < v => Node(insert(l, x), v, r)
  Node(l, v, r) => Node(l, v, insert(r, x))
}
fn items<T>(Leaf: Tree<T>): [T] = []
fn items<T>(Node(l, v, r): Tree<T>): [T] = items(l) + [v] + items(r)
shape Same { fn same(self, o: Self): bool }
struct Id { n: int }
fn same(a: Id, b: Id): bool = a.n == b.n
fn all_same(xs: [Same]): bool = xs.all(x => x.same(xs[0]))
struct Money { cents: int }
fn show(m: Money): str = "${m.cents / 100}"
fn unbox<T>(b: Box<T>): T = b.v
test "generics" {
  assert unbox(Box { v: 3 }) == 3
  let bs: Box<str> = Box { v: "x" }
  assert bs.v == "x"
  var t: Tree<int> = Leaf
  for x in [3, 1, 2] { t = insert(t, x) }
  assert items(t) == [1, 2, 3]
  assert all_same([Id { n: 1 }, Id { n: 1 }])
  let m = Money { cents: 250 }
  assert "{m}" == "$2" && [m].join(",") == "$2"
  let f = unbox
  assert f(Box { v: 1 }) == 1
}
"#;

const SPEC_EXAMPLES: &str = r#"
struct Config { name: str }
struct User { id: int, name: str }
enum ParseErr { BadToken(at: int), Eof }
struct Ast { n: int }
struct Point { x: float, y: float }
enum Shape { Circle(r: float), Rect(w: float, h: float) }
fn area(s: Shape): float = match s {
  Circle(r) => 3.14 * r * r
  Rect(w, h) when w == h => w * w
  Rect(w, h) => w * h
}
fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)
fn len([], acc: int): int = acc
fn len([_, ..t]: [int], acc: int): int = len(t, acc + 1)
fn grade(n: int): str when n >= 90 = "A"
fn grade(_: int): str = "B"
fn parse_cfg(text: str): Config! = Config { name: text }
fn load(path: str): Config! uses fs {
  let text = fs.read(path)?
  parse_cfg(text)?
}
fn default(): Config = Config { name: "x" }
fn parse(s: str): Ast!ParseErr {
  if s == "" { fail(Eof) }
  Ast { n: s.len() }
}
fn find(xs: [User], id: int): User? = xs.find(u => u.id == id)
fn first_or_zero(xs: [int]): int {
  let [h, ..t] = xs else { return 0 }
  h + t.len()
}
fn nums(strs: [str]): [int]! = strs.map(s => int.parse(s))?
fn isqrt(n: int): int
  requires n >= 0
  ensures result * result <= n
{ ?? }
fn deposit(a: var Point, d: float)
  ensures a.x == old(a.x) + d
{
  a.x += d
}
async fn get(url: str): str! uses net {
  var c = net.tcp(url, 80)?
  c.close()
  url
}
async fn both(u1: str, u2: str): [str!]! uses net {
  let page = await get(u1)?
  let (a, b) = await (get(u1), get(u2))
  let all = await [u1, u2].map(u => get(u))
  [a, b] + all + [page]
}
test "isqrt" { assert isqrt(17) == 4 }
fn main(args: [str]): int! uses fs {
  var n: int = 0
  n += 1
  let p = Point { x: 1.0, y: 2.0 }
  let q = Point { x: 3.0, ..p }
  let (x, y) = (1.0, 2.0)
  let r = Point { x, y }
  let c = load("a.toml") else e => default()
  let k = int.parse("12") else 0
  let name = find([User { id: 1, name: "ann" }], 1)?.name else "nobody"
  let v = loop { if k > 0 { break 42 } }
  for i, (a, b) in [(1, 2)] { print(i + a + b) }
  print("{c.name} {k} {name} {v} {area(Circle(2.0)) + q.x + r.y} {fib(10)} {len([1, 2], 0)} {grade(95)} {core.str(1)}")
  print(parse("x") is err(Eof))
  0
}
"#;

// ---- types ----

#[test]
fn mismatch_wrong_return_type() {
    let d = one("fn f(a: int): str = a\n", "E0200", "expected `str`, found `int`");
    has_note(&d, "convert with `str(x)`");
    fix(&d, (1, 15, 1, 18), "int");
}

#[test]
fn mismatch_missing_return_type() {
    let d = one("fn f(n: int) = n * 2\n", "E0200", "this function has no return type, so it returns `()`, but its body is an `int`");
    fix(&d, (1, 13, 1, 13), ": int");
}

#[test]
fn mismatch_argument() {
    let d = one("fn twice(n: int): int = n * 2\nfn main() { print(twice(\"two\")) }\n", "E0200", "expected `int`, found `str`");
    assert_eq!((d.line, d.col), (2, 25));
}

#[test]
fn mismatch_int_literal_for_float() {
    let d = one("fn f(x: float): float = x * 2\n", "E0260", "can't apply `*` to `float` and `int`");
    fix(&d, (1, 29, 1, 30), "2.0");
}

#[test]
fn mismatch_mixed_numbers_suggests_conversion() {
    let d = one("fn f(n: int, x: float): float = x + n\n", "E0260", "can't apply `+` to `float` and `int`");
    fix(&d, (1, 37, 1, 37), "float(");
    fix(&d, (1, 38, 1, 38), ")");
}

#[test]
fn missing_question_mark() {
    let d = one("fn g(): int! = 1\nfn f(): int! {\n  let x: int = g()\n  x\n}\n", "E0201", "expected `int`, found `int!`: the value may be an error");
    has_note(&d, "add `?`");
    fix(&d, (3, 19, 3, 19), "?");
}

#[test]
fn missing_question_mark_without_fallible_return() {
    let d = one("fn g(): int! = 1\nfn f(): int = g()\n", "E0201", "expected `int`, found `int!`: the value may be an error");
    has_note(&d, "handle it with `else`");
    assert!(d.fixes.is_empty() || d.fixes.iter().all(|f| f.4 != "?"), "{d:#?}");
}

#[test]
fn try_in_plain_function_suggests_fallible_return() {
    let d = one("fn f(): int {\n  let n = int.parse(\"1\")?\n  n\n}\n", "E0243", "`?` passes an error up, but this function returns `int`");
    fix(&d, (1, 9, 1, 12), "int!");
}

#[test]
fn try_on_optional_in_result_function() {
    let d = one("fn f(xs: [int]): int! {\n  let x = xs.first()?\n  x\n}\n", "E0249", "`?` on an optional `int?` in a function that returns `int!`");
    has_note(&d, "else fail(");
}

#[test]
fn try_cannot_convert_between_error_enums() {
    one(
        "enum E { A }\nenum F { B }\nfn g(): int!E = 1\nfn f(): int!F {\n  let x = g()?\n  x\n}\n",
        "E0247",
        "`?` can't pass an `E` error up: this function returns `int!F`",
    );
}

#[test]
fn try_on_plain_value() {
    let d = one("fn main() { print(1?) }\n", "E0250", "`?` needs a `T!`, `T?` or a list of them, but `1` is `int`");
    fix(&d, (1, 20, 1, 21), "");
}

#[test]
fn optional_chaining_on_result() {
    let d = one("fn g(): int! = 1\nfn main(): ()! { print(g()?.show()) }\n", "E0252", "`?.` works on `T?` only, but `g()` is `int!`");
    fix(&d, (2, 24, 2, 29), "(g()?).");
}

#[test]
fn optional_chaining_on_plain_value() {
    let d = one("fn main() { print(5?.show()) }\n", "E0253", "`?.` needs an optional `T?`, but `5` is `int`");
    fix(&d, (1, 20, 1, 22), ".");
}

#[test]
fn field_of_optional_suggests_chaining() {
    let d = one("struct P { x: int }\nfn f(p: P?): int = p.x\n", "E0222", "`p` may be missing (`P?`), so it has no field `x`");
    fix(&d, (2, 21, 2, 22), "?.");
}

#[test]
fn tuple_element_of_optional_suggests_chaining() {
    let d = one("fn f(p: (int, str)?): str = p.1\n", "E0223", "`p` may be missing (`(int, str)?`), so it has no element 1");
    fix(&d, (1, 30, 1, 31), "?.");
    one("fn f(p: (int, str)?): int? = p?.2\n", "E0223", "the tuple `(int, str)` has no element 2");
    one("fn f(p: int?): int? = p?.0\n", "E0223", "`?.0` needs an optional tuple, found `int?`");
}

#[test]
fn unwrap_plain_value() {
    let d = one("fn main() { print(1!) }\n", "E0251", "`!` unwraps a `T?` or `T!`, but this is `int`");
    fix(&d, (1, 20, 1, 21), "");
}

#[test]
fn else_on_plain_value() {
    let d = one("fn main() {\n  let x = 1 else 2\n}\n", "E0255", "this `let` always succeeds: `1` is a plain `int` and the pattern always matches");
    fix(&d, (2, 12, 2, 19), "");
}

#[test]
fn else_binder_on_optional() {
    let d = one(
        "fn main() {\n  let x = [1].first() else e => 0\n}\n",
        "E0254",
        "`else e =>` binds an error, but the value is optional (`T?`), so there is none",
    );
    fix(&d, (2, 28, 2, 33), "");
}

#[test]
fn refutable_let_else_must_diverge() {
    one(
        "fn f(xs: [int]): int {\n  let [h, ..t] = xs else 0\n  h\n}\n",
        "E0240",
        "the `else` of a refutable `let` must leave the block (return, break, continue or fail), but this is an `int`",
    );
}

#[test]
fn fail_outside_fallible_function() {
    let d = one("fn f(): int {\n  fail(\"x\")\n}\n", "E0242", "`fail` can only be used in a function that returns `T!` or `T!E` (or in a test)");
    fix(&d, (1, 9, 1, 12), "int!");
}

#[test]
fn fail_with_wrong_value() {
    one("fn f(): int! {\n  fail(3)\n}\n", "E0241", "`fail` needs a `str` message, an `Err` or an error enum value, found `int`");
}

#[test]
fn fail_with_message_in_typed_error_function() {
    one("enum E { A }\nfn f(): int!E {\n  fail(\"x\")\n}\n", "E0241", "this function's errors are `E`, so it can't fail with a message");
}

#[test]
fn if_without_else_as_value() {
    one("fn f(c: bool): int = if c { 1 }\n", "E0205", "an `if` without `else` has no value, but an `int` is expected here");
}

#[test]
fn integer_literal_out_of_range_in_pattern() {
    one("fn f(99999999999999999999): int = 0\n", "E0005", "integer literal does not fit in 64 bits");
}

#[test]
fn cannot_infer_empty_list() {
    let d = one("fn main() { let xs = [] }\n", "E0360", "can't infer the type of this expression");
    assert_eq!((d.line, d.col), (1, 22));
}

#[test]
fn guards_cannot_fail() {
    one("fn f(s: str): int when int.parse(s)? > 0 = 1\nfn f(_: str): int = 0\n", "E0246", "`?` is not allowed in a guard");
}

#[test]
fn ignored_error() {
    let d = one(
        "fn save(): ()! = ()\nfn main(): ()! {\n  save()\n  print(1)\n}\n",
        "E0334",
        "the result of `save()` is a `()!`, and its error is ignored",
    );
    fix(&d, (3, 9, 3, 9), "?");
    assert!(check("fn save(): ()! = ()\nfn main() {\n  let _ = save()\n}\n").is_empty());
}

#[test]
fn branch_mismatch_does_not_blame_return_type() {
    let d = one("fn f(c: bool): bool = if c { true } else { 1 }\n", "E0200", "expected `bool`, found `int`");
    assert!(d.fixes.is_empty(), "{d:#?}");
}

#[test]
fn no_cascade_after_bad_receiver() {
    let ds = check("struct S { xs: [int] }\nfn f(s: S): bool = s?.xs.all(x => x > 0)\n");
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!(ds[0].code, "E0253");
}

// ---- names, fields, methods ----

#[test]
fn unknown_name_suggests_similar() {
    let d = one("fn main() {\n  let count = 1\n  print(cout)\n}\n", "E0102", "unknown name `cout`");
    has_note(&d, "did you mean `count`?");
    fix(&d, (3, 9, 3, 13), "count");
}

#[test]
fn unknown_function() {
    one("fn main() { frobnicate(1) }\n", "E0102", "unknown function `frobnicate`");
}

#[test]
fn unknown_field_suggests_similar() {
    let d = one("struct P { name: str }\nfn f(p: P): str = p.nmae\n", "E0221", "the struct `P` has no field `nmae`");
    has_note(&d, "its fields are: name");
    fix(&d, (2, 21, 2, 25), "name");
}

#[test]
fn unknown_method() {
    let d = one("fn main() { [1, 2].frob() }\n", "E0103", "no function `frob` takes a `[int]` first (1 argument(s))");
    assert_eq!((d.line, d.col), (1, 20));
}

#[test]
fn method_exists_for_other_types() {
    let d = one("fn main() { print(5.trim()) }\n", "E0103", "no function `trim` takes an `int` first (1 argument(s))");
    has_note(&d, "trim(str): str");
}

#[test]
fn unknown_type_suggests_str() {
    let d = one("fn f(s: string) {}\n", "E0104", "unknown type `string`");
    fix(&d, (1, 9, 1, 15), "str");
}

#[test]
fn unknown_struct_field_in_literal() {
    let d = one("struct P { x: int }\nfn main() { print(P { x: 1, z: 2 }) }\n", "E0225", "the struct `P` has no field `z`");
    fix(&d, (2, 29, 2, 30), "x");
}

#[test]
fn missing_struct_fields() {
    one("struct P { x: int, y: int }\nfn main() { print(P { x: 1 }) }\n", "E0224", "the struct literal is missing field(s) `y` of `P`");
}

#[test]
fn shape_used_as_value_type() {
    let d = one("fn main() {\n  let v: Show = 1\n}\n", "E0105", "the shape `Show` can't be used as a type here");
    fix(&d, (2, 10, 2, 14), "any Show");
}

// ---- overloading ----

#[test]
fn ambiguous_overload() {
    let d = one(
        "fn f<T>(x: [T]): int = 1\nfn f(x: [int]): int = 2\nfn main() { print(f([1])) }\n",
        "E0301",
        "the call to `f` is ambiguous: 2 overloads take a `[int]` first",
    );
    has_note(&d, "f([T]): int; f([int]): int");
}

#[test]
fn no_overload_for_first_argument() {
    let d = one(
        "fn show2(n: int): str = \"\"\nfn show2(s: str): str = s\nfn main() { print(show2(1.5)) }\n",
        "E0202",
        "no `show2` takes a first argument of type `float`",
    );
    has_note(&d, "show2(int): str; show2(str): str");
}

#[test]
fn wrong_argument_count() {
    let d = one("fn f(a: int, b: int) {}\nfn main() { f(1) }\n", "E0300", "`f` takes 2 argument(s), but 1 were given");
    has_note(&d, "f(int, int)");
}

#[test]
fn overloads_split_by_first_parameter_type() {
    assert!(check("struct A { a: int }\nstruct B { b: int }\nfn show(x: A): str = \"a\"\nfn show(x: B): str = \"b\"\nfn main() { print(show(A { a: 1 }) + B { b: 2 }.show()) }\n").is_empty());
}

#[test]
fn duplicate_function() {
    let d = one(
        "fn f(x: int) = ()\nfn g() = ()\nfn f(y: int) = ()\n",
        "E0111",
        "`f` is defined twice with a first parameter of type `int` taking 1 parameter(s)",
    );
    has_note(&d, "must be contiguous");
}

#[test]
fn clause_parameter_types_disagree() {
    let d = one(
        "fn f(0, s: str): int = 0\nfn f(n: int, s: int): int = 1\n",
        "E0108",
        "this clause of `f` declares parameter 2 as `int`, but an earlier clause says `str`",
    );
    fix(&d, (2, 17, 2, 20), "str");
}

#[test]
fn parameter_type_unknown() {
    one("fn f(x) = ()\n", "E0109", "can't tell the type of parameter 1 of `f`");
}

#[test]
fn user_operator_missing() {
    let d = one("struct V { x: int }\nfn main() { print(V { x: 1 } + V { x: 2 }) }\n", "E0261", "`+` isn't defined for `V`");
    has_note(&d, "define `fn add(a: V, b: V): V`");
}

// ---- shapes ----

#[test]
fn shape_fit_failure_names_missing_function() {
    let d = one(
        "shape Area { fn area(self): float }\nstruct Tri { a: float }\nfn total(xs: [Area]): float = 0.0\nfn main() { print(total([Tri { a: 1.0 }])) }\n",
        "E0350",
        "`Tri` doesn't fit the shape `Area`, which `total` needs (it takes `Area` values)",
    );
    has_note(&d, "fn area(x: Tri): float");
}

#[test]
fn ord_not_automatic_for_structs() {
    let d = one(
        "struct P { x: int }\nfn main() { print([P { x: 1 }].sort()) }\n",
        "E0350",
        "`P` doesn't fit the shape `Ord`, which `sort` needs for its type parameter `T`",
    );
    has_note(&d, "define `fn cmp(a: P, b: P): int`");
}

#[test]
fn user_cmp_makes_a_type_ord() {
    assert!(check("struct P { x: int }\nfn cmp(a: P, b: P): int = a.x - b.x\nfn main() { print([P { x: 1 }].sort().len()) }\n").is_empty());
}

#[test]
fn closures_are_not_show() {
    let d = one(
        "fn main() { print(x => x + 1) }\n",
        "E0350",
        "`(int) => int` doesn't fit the shape `Show`, which `print` needs for its type parameter `T`",
    );
    has_note(&d, "closures don't fit");
}

#[test]
fn type_parameter_needs_bound() {
    let d = one("fn f<T>(x: T): str = \"{x}\"\n", "E0350", "`T` doesn't fit the shape `Show`, to interpolate it into a string");
    has_note(&d, "<T: Show>");
}

// ---- var parameters and mutability ----

#[test]
fn missing_ampersand() {
    let d = one(
        "fn f(xs: var [int]) { xs.push(1) }\nfn main() {\n  var a = [1]\n  f(a)\n}\n",
        "E0310",
        "parameter `xs` of `f` is `var`, so the argument needs `&`",
    );
    fix(&d, (4, 5, 4, 5), "&");
}

#[test]
fn ampersand_on_plain_parameter() {
    let d = one(
        "fn f(xs: [int]) {}\nfn main() {\n  var a = [1]\n  f(&a)\n}\n",
        "E0311",
        "parameter 1 of `f` is not a `var` parameter, so its argument takes no `&`",
    );
    fix(&d, (4, 5, 4, 6), "");
}

#[test]
fn assign_to_let() {
    let d = one("fn main() {\n  let n = 1\n  n += 1\n}\n", "E0320", "can't assign to `n`: it isn't mutable");
    fix(&d, (2, 3, 2, 6), "var");
}

#[test]
fn ref_to_let() {
    let d = one("fn f(xs: var [int]) {}\nfn main() {\n  let a = [1]\n  f(&a)\n}\n", "E0320", "can't pass `&a`: `a` isn't mutable");
    fix(&d, (3, 3, 3, 6), "var");
}

#[test]
fn mutating_method_on_let() {
    let d = one("fn main() {\n  let xs = [1]\n  xs.push(2)\n}\n", "E0320", "`push` changes its first argument, but `xs` isn't mutable");
    fix(&d, (2, 3, 2, 6), "var");
}

#[test]
fn assign_to_plain_parameter() {
    let d = one("fn f(n: int) {\n  n = 3\n}\n", "E0320", "can't assign to `n`: it isn't mutable");
    fix(&d, (1, 9, 1, 9), "var ");
}

#[test]
fn closure_cannot_assign_capture() {
    one("fn main() {\n  var n = 0\n  let f = () => { n = 1 }\n}\n", "E0323", "a closure can't change `n`, a variable it captures");
}

#[test]
fn strings_are_immutable() {
    one("fn main() {\n  var s = \"ab\"\n  s[0] = 'c'\n}\n", "E0322", "strings are immutable: `s[i]` can't be assigned");
}

// ---- async ----

#[test]
fn unawaited_async_call() {
    let d = one("async fn get(): int = 1\nfn main() {\n  get()\n  print(1)\n}\n", "E0332", "this `async fn` call is never awaited");
    fix(&d, (3, 3, 3, 3), "await ");
}

#[test]
fn async_result_used_without_await() {
    let d = one(
        "async fn get(): int = 1\nfn main() { print(get() + 1) }\n",
        "E0333",
        "`get()` is an un-awaited `async fn` call, so `+` can't use its value",
    );
    fix(&d, (2, 19, 2, 19), "await ");
}

#[test]
fn async_returned_where_value_expected() {
    let d = one("async fn get(): int = 1\nfn f(): int = get()\n", "E0333", "expected `int`, found an un-awaited `async fn` call");
    fix(&d, (2, 15, 2, 15), "await ");
}

#[test]
fn await_non_task() {
    let d = one(
        "fn main() { let x = await 1 }\n",
        "E0331",
        "`await` needs an `async fn` call, a task, a tuple of tasks or a list of tasks, but `1` is `int`",
    );
    fix(&d, (1, 21, 1, 27), "");
}

// ---- interpolation ----

#[test]
fn format_precision_on_int() {
    one("fn main(n: int) {}\n", "E0370", "`main` has an unsupported signature: (int) returning `()`");
    let d = one("fn f(n: int): str = \"{n:.2}\"\n", "E0280", "the format spec `.2` has a precision, which applies to `float` and `str`, not `int`");
    assert_eq!((d.line, d.col), (1, 23));
}

#[test]
fn format_zero_pad_on_str() {
    one("fn f(s: str): str = \"{s:05}\"\n", "E0281", "the format spec `05` pads with zeros, which applies to numbers, not `str`");
}

#[test]
fn format_malformed() {
    one("fn f(n: int): str = \"{n:e}\"\n", "E0282", "malformed format spec `e`: unexpected `e`");
}

#[test]
fn format_specs_that_fit() {
    assert!(check("fn f(x: float, n: int, s: str): str = \"{x:.2} {n:>5} {n:05} {s:<10} {s:.3} {s:-^9} {x:08.3}\"\n").is_empty());
}

// ---- patterns ----

#[test]
fn pattern_type_mismatch() {
    one("fn f(x: int): int = match x {\n  \"a\" => 1\n  _ => 2\n}\n", "E0262", "this pattern matches a `str`, but the value is an `int`");
}

#[test]
fn is_pattern_cannot_bind() {
    let d = one("fn f(x: int?): bool = x is some(y)\n", "E0263", "an `is` pattern can't bind names, but `y` would bind one");
    fix(&d, (1, 33, 1, 34), "_");
}

#[test]
fn variant_pattern_field_count() {
    one(
        "enum E { A(x: int, y: int) }\nfn f(e: E): int = match e {\n  A(x) => x\n}\n",
        "E0264",
        "the variant `A` has 2 field(s), but the pattern has 1",
    );
}

#[test]
fn duplicate_binding() {
    one("fn f(p: (int, int)): int = match p {\n  (a, a) => a\n}\n", "E0265", "`a` is bound twice in this pattern");
}

#[test]
fn struct_pattern_needs_rest() {
    let d = one(
        "struct P { x: int, y: int }\nfn f(p: P): int = match p {\n  P { x } => x\n}\n",
        "E0266",
        "this pattern doesn't mention the field(s) `y` of `P`",
    );
    fix(&d, (3, 9, 3, 9), ", ..");
}

#[test]
fn bare_variant_name_matches_variant() {
    // `Eof` is a variant in scope, so it matches it (not a binding); `other` binds
    assert!(check("enum T { Eof, Word(s: str) }\nfn f(t: T): str = match t {\n  Eof => \"end\"\n  other => \"word\"\n}\n").is_empty());
}

// ---- control flow ----

#[test]
fn break_outside_loop() {
    one("fn main() { break }\n", "E0244", "`break` outside a loop");
}

#[test]
fn break_value_in_while() {
    one("fn main() {\n  while true { break 1 }\n}\n", "E0245", "only `loop` can `break` with a value");
}

#[test]
fn loop_over_string_suggests_chars() {
    let d = one("fn main() {\n  for c in \"abc\" { print(c) }\n}\n", "E0207", "can't loop over a `str`");
    fix(&d, (2, 17, 2, 17), ".chars()");
}

#[test]
fn index_non_indexable() {
    one("fn main() { print(5[0]) }\n", "E0270", "can't index an `int`");
}

// ---- modules, privacy, packages ----

/// A project with `raft.toml` and the given `src/` files; returns its directory.
fn project(files: &[(&str, &str)], deps: &[&str]) -> PathBuf {
    let dir = scratch();
    let mut toml = String::from("[package]\nname = \"app\"\nversion = \"0.1.0\"\n");
    if !deps.is_empty() {
        toml += "\n[deps]\n";
        for d in deps {
            toml += &format!("{d} = \"^0.1\"\n");
        }
    }
    fs::write(dir.join("raft.toml"), toml).unwrap();
    for (name, src) in files {
        let p = dir.join("src").join(name);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, src).unwrap();
    }
    dir
}

const GEO: &str = "pub struct Circle { r: float }\npub enum Kind { Big, Small }\npub fn area(c: Circle): float = 3.14 * c.r * c.r * float(app.helper())\nfn secret(): int = 2\n";

#[test]
fn project_modules_and_paths() {
    let main = "pub fn helper(): int = 1\nfn main() {\n  let c = geo.Circle { r: 1.0 }\n  print(geo.area(c) + c.area())\n  print(geo.shapes.sides(geo.shapes.Tri))\n  let k: geo.Kind = geo.Big\n  print(k == geo.Kind.Small)\n  match k { Big => print(\"big\"), _ => {} }\n}\n";
    let shapes = "pub enum Poly { Tri, Quad }\npub fn sides(Tri): int = 3\npub fn sides(Quad): int = 4\n";
    let dir = project(&[("main.auk", main), ("geo.auk", GEO), ("geo/shapes.auk", shapes)], &[]);
    let ds = check_path(&dir.join("src/main.auk"));
    assert!(ds.is_empty(), "{ds:#?}");
}

#[test]
fn private_function_of_other_module() {
    let main = "pub fn helper(): int = 1\nfn main() { print(geo.secret()) }\n";
    let dir = project(&[("main.auk", main), ("geo.auk", GEO)], &[]);
    let ds = check_path(&dir.join("src/main.auk"));
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!((ds[0].code.as_str(), ds[0].message.as_str()), ("E0120", "`secret` is private to module `app.geo`"));
}

#[test]
fn private_field_type_hides_field() {
    let lib = "struct Hidden { x: int }\npub struct Pt { x: int, h: Hidden }\npub fn make(): Pt = Pt { x: 1, h: Hidden { x: 2 } }\n";
    let main = "fn main() {\n  let p = lib.make()\n  print(p.x)\n  print(p.h)\n}\n";
    let dir = project(&[("main.auk", main), ("lib2.auk", &lib.replace("lib", "lib2"))], &[]);
    let main2 = main.replace("lib.", "lib2.");
    fs::write(dir.join("src/main.auk"), main2).unwrap();
    let ds = check_path(&dir.join("src/main.auk"));
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!((ds[0].code.as_str(), ds[0].message.as_str()), ("E0121", "the field `h` of `Pt` is private to module `app.lib2`"));
    has_note(&ds[0], "its type is private to that module");
}

#[test]
fn missing_dependency() {
    let dir = project(&[("main.auk", "fn main() {}\n")], &["json"]);
    let ds = check_path(&dir.join("src/main.auk"));
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!((ds[0].code.as_str(), ds[0].message.as_str()), ("E0100", "dependency `json` of `app` is not installed"));
    has_note(&ds[0], "raft install");
}

#[test]
fn module_colliding_with_dependency() {
    let dir = project(&[("main.auk", "fn main() {}\n"), ("json.auk", "pub fn x() = ()\n")], &["json"]);
    let q = dir.join(".raft/json/src");
    fs::create_dir_all(&q).unwrap();
    fs::write(q.join("lib.auk"), "pub fn parse(s: str): int = 1\n").unwrap();
    fs::write(dir.join(".raft/json/raft.toml"), "[package]\nname = \"json\"\nversion = \"0.1.0\"\n").unwrap();
    let ds = check_path(&dir.join("src/main.auk"));
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!((ds[0].code.as_str(), ds[0].message.as_str()), ("E0101", "module `app.json` has the same name as the dependency `json`"));
}

#[test]
fn dependency_paths_and_name_rule() {
    setup();
    // `regex(p)` means `regex.regex(p)`; dependency variants match unqualified by type
    let dir = project(
        &[(
            "main.auk",
            "fn main(): ()! {\n  let r = regex(\"a+\")?\n  print(r.find(\"baa\") else \"\")\n  match regex(\"(\") {\n    err(Unclosed(at, _)) => print(at)\n    _ => print(0)\n  }\n  let v = json.parse(\"[1]\")?\n  print(json.str(v))\n}\n",
        )],
        &["regex", "json"],
    );
    let out = Command::new(env!("CARGO_BIN_EXE_raft")).arg("install").current_dir(&dir).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let ds = check_path(&dir.join("src/main.auk"));
    assert!(ds.is_empty(), "{ds:#?}");
}

#[test]
fn extern_needs_the_ffi_effect() {
    // a standalone file has no raft.toml to declare `ffi` in (projects: tests/ffi.rs)
    one("extern fn f(): int = \"int f(void)\"\n", "E0036", "`extern` declarations need the `ffi` effect in the package's raft.toml");
}

#[test]
fn main_signature() {
    one("fn main(x: int) {}\n", "E0370", "`main` has an unsupported signature: (int) returning `()`");
}

#[test]
fn text_output_renders_fixes() {
    let dir = scratch();
    let path = dir.join("t.auk");
    fs::write(&path, "fn f(xs: var [int]) {}\nfn main() {\n  var a = [1]\n  f(a)\n}\n").unwrap();
    let out = auk(&["check", path.to_str().unwrap()]);
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success());
    assert!(err.contains("error[E0310]: parameter `xs` of `f` is `var`, so the argument needs `&`"), "{err}");
    assert!(err.contains("= fix: insert `&` at 4:5"), "{err}");
}

#[test]
fn map_pattern_starts_a_match_arm() {
    // on a map, on the first arm and on a later one (the lexer joins a line starting with `{`)
    let src = "fn f(v: {str: int}): int {\n  match v {\n    {\"b\": n} => n\n    {\"a\": n} => n + 1\n    _ => 0\n  }\n}\n\
               fn g(v: {str: int}): int = match v { {\"a\": n} => n, _ => 0 }\n\
               fn h(v: Value): int {\n  match v {\n    Value.Null => 0\n    {\"a\": Value.Int(n)} => n\n    _ => 1\n  }\n}\n\
               fn main() {}\n";
    let ds = check(src);
    assert!(ds.is_empty(), "{ds:#?}");
    // the bound value really is type-checked: `n` is an `int`
    let d = one(
        "fn f(v: {str: int}): str {\n  match v {\n    _ when false => \"\"\n    {\"a\": n} => n\n    _ => \"\"\n  }\n}\nfn main() {}\n",
        "E0200",
        "expected `str`, found `int`",
    );
    assert_eq!((d.line, d.col), (4, 17));
}
