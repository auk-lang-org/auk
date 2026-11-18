# toml

Converts TOML 1.0 text to and from the core `Value` tree, and to and from your own types through the compiler-derived `to_value`/`from_value`. It handles every TOML 1.0 feature: bare, quoted and dotted keys, `[tables]`, `[[arrays of tables]]`, inline tables, all four string kinds, integers with `_` and `0x`/`0o`/`0b`, floats including `inf`/`nan`, booleans, and dates and times. It enforces the spec's rules on redefining tables and keys. Parse errors are a typed `TomlErr` that carries the line and column. The API mirrors `json`.

**Effects:** none. **Dependencies:** none.

```auk
struct Server { host: str, port: int }
struct Config { title: str, debug: bool, server: Server }

let v = toml.parse("title = \"demo\"\n[server]\nport = 8080")?   // Map({"title": Str("demo"), "server": Map({"port": Int(8080)})})
let c: Config = toml.decode(fs.read("app.toml")?)?
fs.write("app.toml", toml.encode(c)?)?
match toml.parse("a: 1") {
  err(e) => print(toml.message(e))                                // 1:2: expected '=', found ':'
  ok(_) => {}
}
```

## API
- `enum TomlErr { Unexpected(found: char, want: str, line, col), Eof(want: str, line, col), BadNumber(text: str, line, col), BadDateTime(text: str, line, col), BadEscape(text: str, line, col), ControlChar(line, col), DuplicateKey(key: str, line, col), NotATable(key: str, line, col), TooDeep(line, col) }`: all positions are `int` and 1-based (columns count chars). `want` says what was expected, for example `"'='"` or `"a value"`. `key` is the full dotted path, for example `fruit.apple`.
- `parse(s: str): Value!TomlErr`: the document as a `Map`. Tables and inline tables become `Map`, with keys in document order. Arrays and arrays of tables become `List`, integers `Int`, floats `Float`, and booleans `Bool`. Arrays, inline tables and their combinations can nest up to `MAX_DEPTH` (512) levels.
- `str(v: Value): str!`: TOML text. Each table's plain `key = value` lines come first, then its `[sub.tables]`, then its `[[arrays.of.tables]]` (a non-empty `List` whose items are all `Map`s). Keys keep map order and are quoted only when they aren't bare. A `[header]` is left out for a table that holds only other tables. `Null` map entries are omitted, because TOML has no null. The call fails when the root isn't a `Map` or when a `Null` sits inside an array. Floats always keep a `.` or an exponent; NaN and the infinities are written `nan`, `inf` and `-inf`.
- `decode<T: Data>(s: str): T!`: `parse` followed by the derived `from_value`; the type `T` comes from the annotation (`let c: Config = toml.decode(s)?`). An integer fills a `float` field.
- `encode<T: Data>(x: T): str!`: the derived `to_value` followed by `str`, so `x` must be a struct or a `{str: T}` map.
- `message(e: TomlErr): str`: a one-line description, for example `4:2: 'fruit' is already defined`.

## Dates and times
`Value` has no date variant, so TOML dates and times parse to `Str` in RFC 3339 form. Each one is validated first, including the month, the day of the month (leap years included), the hour, the minute, the second (60 is allowed for a leap second) and the offset. The text is kept as written, except that a space or `t` between the date and the time becomes `T` and a `z` offset becomes `Z`:

| TOML | parses to |
|---|---|
| `1979-05-27T07:32:00Z`, `1979-05-27 07:32:00z` | `Str("1979-05-27T07:32:00Z")` |
| `1979-05-27T00:32:00.999999-07:00` | `Str("1979-05-27T00:32:00.999999-07:00")` |
| `1979-05-27T07:32:00` (local) | `Str("1979-05-27T07:32:00")` |
| `1979-05-27` (local date) | `Str("1979-05-27")` |
| `07:32:00` (local time) | `Str("07:32:00")` |

The writer can't tell such a string from any other, so `str` writes it as a quoted string. Reading it back gives the same `Str`, but other TOML readers see a string, not a date.

## Limits in 0.1
- Seconds are required in times, as TOML 1.0 says. TOML 1.1's optional seconds, `\e` and `\xHH` escapes, and newlines inside inline tables aren't accepted yet.
- Integers must fit in 64 bits; a larger one is a `BadNumber` error. Floats beyond the `float` range become `inf`.
- `-nan` and `+nan` parse to the same NaN.
- `\r\n` inside multi-line strings is read as `\n`.
- `str` doesn't keep comments, formatting or the original key order of a parsed file beyond what the `Map` holds.
