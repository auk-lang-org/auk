# json

Converts JSON text (RFC 8259) to and from the core `Value` tree, and to and from your own types through the compiler-derived `to_value`/`from_value`. Parse errors are a typed `JsonErr` that carries the line and column. Integers parse to `Int`, and any number with a fraction or exponent parses to `Float`. The writers put object keys in sorted order, so their output is deterministic.

**Effects:** none.

```auk
struct Todo { id: int, title: str, done: bool }

let v = json.parse("[1, 2.5, \"x\", null]")?       // List([Int(1), Float(2.5), Str("x"), Null])
print(json.pretty(v))
let ts: [Todo] = json.decode(fs.read("todos.json")?)?
fs.write("todos.json", json.encode(ts))?
match json.parse("[1,]") {
  err(e) => print(json.message(e))                  // 1:4: unexpected ']'
  ok(_) => {}
}
```

## API
- `enum JsonErr { Unexpected(found: char, line, col), Eof(line, col), BadNumber(text: str, line, col), BadEscape(text: str, line, col), ControlChar(line, col), TooDeep(line, col) }` (all positions are `int` and 1-based)
- `parse(s: str): Value!JsonErr`: strict RFC 8259 parsing, nested up to `MAX_DEPTH` (512) levels; a repeated key keeps its last value
- `str(v: Value): str`: compact output; NaN and infinity are written as `null`
- `pretty(v: Value): str`: 2-space indent
- `decode<T: Data>(s: str): T!`: `parse` followed by the derived `from_value`; the type `T` comes from the annotation (`let t: Todo = json.decode(s)?`)
- `encode<T: Data>(x: T): str`: the derived `to_value` followed by `str`
- `message(e: JsonErr): str`: a one-line description such as `2:11: unexpected '}'`
