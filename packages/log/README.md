# log

Leveled, structured logging to stderr, as [logfmt](https://brandur.org/logfmt) or JSON lines. There is no global logger (Auk has no global mutable state): build a `Logger` value and pass it around, or keep one in a module-level `let`. Loggers are values, so `with` returns a new logger and never changes the old one.

**Effects:** none (`eprint` is always allowed). Depends on `json` (no effects). Lines carry no timestamp, since reading the clock needs `uses time`; most log collectors add one, or add a field yourself with `.with("ts", time.now())`.

```auk
fn main(): int! uses env {
  let lv = log.level(env.get("LOG") else "info")?
  let l = log.new(lv).with("svc", "api")
  l.info("listening", {"port": Int(8080)})   // level=info msg=listening svc=api port=8080
  l.debug("not shown at info")
  let j = l.json()
  j.warn("slow request", {"ms": Int(950)})   // {"level":"warn","msg":"slow request","svc":"api","ms":950}
  0
}
```

## API
- `enum Level { Debug, Info, Warn, Error }`
- `struct Logger { min: Level, json: bool, fields: {str: Value} }`
- `new(min: Level): Logger`: a logfmt logger that keeps lines at `min` and above.
- `json(l: Logger): Logger`: the same logger, writing one JSON object per line.
- `with<T: Data>(l: Logger, key: str, v: T): Logger`: adds a field to every line (any `Data` value; a struct becomes a nested object). A later `with` of the same key replaces it.
- `debug`, `info`, `warn`, `error` `(l: Logger, msg: str)`, and the same with a third argument `fields: {str: Value}` for fields on this line only.
- `log(l: Logger, lv: Level, msg: str, fields: {str: Value})`: the general form.
- `line(l, lv, msg, fields): str?`: the text that would be written, or none when filtered out (pure; for tests or other sinks).
- `enabled(l: Logger, lv: Level): bool`: skip building an expensive message.
- `level(s: str): Level!`: parses `debug`, `info`, `warn`/`warning` or `error`, ignoring case and surrounding spaces. `name(lv): str` is the reverse.

Each line is `level`, `msg`, the logger's fields in the order they were added, then the line's own fields. In logfmt, a string value is written bare unless it is empty or contains a space, `=`, `"`, `\` or a control char, in which case it is quoted with JSON escapes. Lists and maps are written as compact JSON. Unsafe chars in keys become `_`.
