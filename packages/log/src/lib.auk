/// Leveled, structured logging to stderr, as logfmt or JSON lines. No global state: build a
/// `Logger` and pass it (or keep one in a module-level `let`). No effects: `eprint` is always
/// allowed. Lines carry no timestamp; add one with `.with("ts", time.now())` if you need it.

/// How important a line is. A logger drops lines below its minimum level.
pub enum Level { Debug, Info, Warn, Error }

/// A logger: its minimum level, output format, and the fields every line carries.
pub struct Logger { min: Level, json: bool, fields: {str: Value} }

/// A logfmt logger (`level=info msg=started port=8080`) that keeps lines at `min` and above.
pub fn new(min: Level): Logger = Logger { min, json: false, fields: {} }

/// The same logger, writing one JSON object per line instead of logfmt.
pub fn json(l: Logger): Logger = Logger { json: true, ..l }

/// The same logger with a field added to every line (a later `with` of the same key replaces it).
/// Any `Data` value works: `l.with("user", "ann").with("attempt", 3)`.
pub fn with<T: Data>(l: Logger, key: str, v: T): Logger {
  var fields = l.fields
  fields[key] = to_value(v)
  Logger { fields, ..l }
}

/// A level from its name, ignoring case: `debug`, `info`, `warn` (or `warning`), `error`.
/// Handy for `log.level(env.get("LOG") else "info")?`.
pub fn level(s: str): Level! = match s.trim().lower() {
  "debug" => Debug
  "info" => Info
  "warn" => Warn
  "warning" => Warn
  "error" => Error
  _ => fail("unknown log level: {s}")
}

/// The lower-case name of a level.
pub fn name(Debug): str = "debug"
pub fn name(Info): str = "info"
pub fn name(Warn): str = "warn"
pub fn name(Error): str = "error"

fn rank(Debug): int = 0
fn rank(Info): int = 1
fn rank(Warn): int = 2
fn rank(Error): int = 3

/// Would a line at `lv` be written? Use it to skip building expensive messages.
pub fn enabled(l: Logger, lv: Level): bool = rank(lv) >= rank(l.min)

pub fn debug(l: Logger, msg: str) { l.log(Debug, msg, {}) }
pub fn info(l: Logger, msg: str) { l.log(Info, msg, {}) }
pub fn warn(l: Logger, msg: str) { l.log(Warn, msg, {}) }
pub fn error(l: Logger, msg: str) { l.log(Error, msg, {}) }

/// The same, with fields for this line only: `l.info("saved", {"id": Int(7)})`.
pub fn debug(l: Logger, msg: str, fields: {str: Value}) { l.log(Debug, msg, fields) }
pub fn info(l: Logger, msg: str, fields: {str: Value}) { l.log(Info, msg, fields) }
pub fn warn(l: Logger, msg: str, fields: {str: Value}) { l.log(Warn, msg, fields) }
pub fn error(l: Logger, msg: str, fields: {str: Value}) { l.log(Error, msg, fields) }

/// Write one line to stderr if `lv` is enabled.
pub fn log(l: Logger, lv: Level, msg: str, fields: {str: Value}) {
  let text = l.line(lv, msg, fields) else return
  eprint(text)
}

/// The text `log` would write (without the line break), or none when `lv` is filtered out.
/// Order: `level`, `msg`, the logger's fields, then this line's fields.
pub fn line(l: Logger, lv: Level, msg: str, fields: {str: Value}): str? {
  if !l.enabled(lv) { return none }
  var all: [(str, Value)] = [("level", Str(name(lv))), ("msg", Str(msg))]
  for k, v in l.fields { all.push((k, v)) }
  for k, v in fields { all.push((k, v)) }
  if l.json {
    let parts = all.map((k, v) => json.str(Str(k)) + ":" + json.str(v))
    some("{{" + parts.join(",") + "}}")
  } else {
    some(all.map((k, v) => "{fmt_key(k)}={logfmt(v)}").join(" "))
  }
}

// ---- logfmt ----

// A logfmt value: bare when it's safe, quoted (JSON-style escapes) otherwise; lists and maps
// are written as compact JSON.
fn logfmt(Str(s)): str = quote_if_needed(s)
fn logfmt(Null): str = "null"
fn logfmt(Bool(b)): str = "{b}"
fn logfmt(Int(n)): str = "{n}"
fn logfmt(Float(f)): str = json.str(Float(f))
fn logfmt(v: Value): str = quote_if_needed(json.str(v))

fn quote_if_needed(s: str): str = if s == "" ||
  s.chars().any(c => c == ' ' || c == '=' || c == '"' || c == '\\' || int(c) < 0x20) {
  json.str(Str(s))
} else {
  s
}

// Keys can't be quoted in logfmt, so unsafe chars become `_`.
fn fmt_key(k: str): str {
  let cs = k.chars().map(
    c => if c == ' ' || c == '=' || c == '"' || int(c) < 0x20 { '_' } else { c },
  )
  if cs.len() == 0 { "_" } else { str(cs) }
}

// ---- tests ----

test "levels filter" {
  let l = new(Warn)
  assert !l.enabled(Debug) && !l.enabled(Info)
  assert l.enabled(Warn) && l.enabled(Error)
  assert l.line(Info, "hi", {}) is none
  assert l.line(Error, "boom", {}) is some("level=error msg=boom")
  assert new(Debug).line(Debug, "x", {}) is some("level=debug msg=x")
}

test "parse level names" {
  assert level("debug")? == Debug
  assert level("INFO")? == Info
  assert level(" Warning ")? == Warn
  assert level("warn")? == Warn
  assert level("error")? == Error
  assert level("loud") is err(_)
  assert [Debug, Info, Warn, Error].map(v => name(v)) == ["debug", "info", "warn", "error"]
}

test "logfmt fields and quoting" {
  let l = new(Info).with("svc", "api").with("port", 8080)
  assert l.line(Info, "started", {}) is some("level=info msg=started svc=api port=8080")
  assert l.line(Info, "request done", {"path": Str("/a b"), "ok": Bool(true), "ms": Float(1.5)}) ==
    some("level=info msg=\"request done\" svc=api port=8080 path=\"/a b\" ok=true ms=1.5")
  let q = new(Debug)
  assert q.line(Info, "", {
    "e": Str("x=\"1\"\n"),
  }) is some("level=info msg=\"\" e=\"x=\\\"1\\\"\\n\"")
  assert q.line(Info, "m", {
    "n": Null,
    "xs": List([Int(1), Int(2)]),
  }) is some("level=info msg=m n=null xs=[1,2]")
  assert q.line(Info, "m", {
    "m": Map({"a": Str("b c")}),
  }) is some("level=info msg=m m=\"{{\\\"a\\\":\\\"b c\\\"}}\"")
  assert q.line(Info, "m", {"bad key=": Int(1)}) is some("level=info msg=m bad_key_=1")
}

test "with replaces a key and keeps order" {
  let l = new(Info).with("a", 1).with("b", 2).with("a", "z")
  assert l.line(Info, "m", {}) is some("level=info msg=m a=z b=2")
  let base = new(Info)
  let _ = base.with("k", 1)
  assert base.fields.len() == 0  // loggers are values: `with` returns a new one
}

struct Req { id: int, path: str }

test "json lines" {
  let l = new(Debug).json().with("svc", "api")
  assert l.line(Warn, "slow \"q\"", {"ms": Int(250)}) ==
    some(r"""{"level":"warn","msg":"slow \"q\"","svc":"api","ms":250}""")
  let r = l.with("req", Req { id: 7, path: "/x" })
  assert r.line(
    Info,
    "ok",
    {},
  ) is some(r"""{"level":"info","msg":"ok","svc":"api","req":{"id":7,"path":"/x"}}""")
  assert new(Error).json().line(Info, "x", {}) is none
}

test "writing does not fail" {
  let l = new(Error)
  l.debug("dropped")
  l.info("dropped", {"k": Int(1)})
  l.warn("dropped")
  l.error("written to stderr by the test", {"k": Int(1)})
}
