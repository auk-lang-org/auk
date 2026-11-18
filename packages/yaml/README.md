# yaml

Converts a practical subset of YAML 1.2 to and from the core `Value` tree, and to and from your own types through the compiler-derived `to_value`/`from_value`. The API mirrors `json` and `toml`. Parse errors are a typed `YamlErr` that carries the line and column.

**Effects:** none. **Dependencies:** none.

```auk
struct Server { host: str, port: int }
struct Config { name: str, debug: bool, servers: [Server] }

let v = yaml.parse("name: demo\ntags: [a, b]")?   // Map({"name": Str("demo"), "tags": List([Str("a"), Str("b")])})
let c: Config = yaml.decode(fs.read("app.yaml")?)?
fs.write("app.yaml", yaml.encode(c))?
match yaml.parse("a:\n\t- b") {
  err(e) => print(yaml.message(e))   // 2:1: tabs can't be used for indentation (use spaces)
  ok(_) => {}
}
```

## What's supported
- **Block collections.**
  - Mappings (`key: value`) and sequences (`- item`) nest by indentation.
  - A sequence may sit at its key's own indentation (`key:\n- a`).
  - Compact forms work: `- name: x` puts a mapping in a sequence, and `- - x` a sequence in a sequence.
- **Flow collections.** `[a, b]` and `{a: 1, b: [x]}` may span lines and allow trailing commas. Inside `[...]`, a single pair like `[a: 1]` becomes a one-key map.
- **Scalars.**
  - Plain scalars may span lines; line breaks fold to spaces.
  - `'single'` quotes escape a quote by doubling it: `''`.
  - `"double"` quotes take every YAML escape: `\n \t \" \\ \/ \0 \a \b \e \f \r \v \N \_ \L \P`, the escaped space and tab, `\xXX`, `\uXXXX`, `\UXXXXXXXX`, and an escaped line break.
- **Block scalars.** These are literal `|` and folded `>`, with the strip `-` and keep `+` chomping indicators and an explicit indentation indicator (`|2`).
- **Comments, documents and anchors.**
  - Comments start with `#`.
  - A stream can hold several documents, separated by `---` and optionally ended by `...`. A `%YAML` directive is accepted.
  - Anchors and aliases (`&name` / `*name`) copy the anchored value; a later `&name` replaces an earlier one.
- **Scalar types (the YAML 1.2 core schema).** A plain scalar becomes:
  - `Null`: `null`, `~` or empty
  - `Bool`: `true` / `false`, or the capitalized or upper-case forms
  - `Int`: decimal, `0o` octal or `0x` hex (a decimal too big for 64 bits becomes a `Float`)
  - `Float`: `1.5`, `-2e3`, `.5`, `.inf`, `-.inf` and `.nan`
  - `Str`: anything else
  
  Quoted scalars are always `Str`. Unlike YAML 1.1, `yes`, `no`, `on`, `off`, `1_000` and `12:30` are strings.
- **Keys.** Keys are the key's text as a `Str`: `1: x` gives the key `"1"`. Map keys keep document order, and a repeated key is an error.

## API
- `enum YamlErr`. All positions are 1-based `int`s, and columns count chars.
  - `Syntax(why: str, line, col)`
  - `Eof(want: str, line, col)`: an unclosed quote, `[` or `{`
  - `Tab(line, col)`: a tab in indentation (tabs between tokens are fine)
  - `BadEscape(text: str, line, col)`
  - `UnknownAlias(name: str, line, col)`
  - `DuplicateKey(key: str, line, col)`
  - `Unsupported(what: str, line, col)`: tags, complex keys or merge keys
  - `ManyDocs(count: int, line, col)`
  - `TooDeep(line, col)`: nesting deeper than `MAX_DEPTH` (512)
- `parse(s: str): Value!YamlErr`: a single document. Empty input gives `Null`. More than one document is a `ManyDocs` error that points at the second one.
- `parse_all(s: str): [Value]!YamlErr`: every document in the stream. Empty input gives `[]`, and an empty document gives `Null`.
- `str(v: Value): str`: YAML text in block style.
  - Maps are written as `key: value` lines and lists as `- item` lines, two spaces per level. A collection inside a list starts on the dash's line.
  - Empty collections are written `{}` and `[]`.
  - A string is written plain when it reads back as the same string. Multi-line text uses a literal block (`|-`, `|` or `|+`, chosen to keep its trailing newlines exactly). Anything else is double-quoted with escapes.
  - Floats keep a `.` or an exponent; the special values are `.inf`, `-.inf` and `.nan`.
  - `parse(str(v)) == v` for every `Value`.
- `decode<T: Data>(s: str): T!`: `parse` followed by the derived `from_value`. The annotation picks `T`: `let c: Config = yaml.decode(s)?`.
- `encode<T: Data>(x: T): str`: the derived `to_value` followed by `str`.
- `resolve(text: str): Value`: how a plain scalar is typed.
- `message(e: YamlErr): str`: a one-line description, for example `3:4: mapping values aren't allowed here`.

## Not supported in 0.1
These are rejected with a clear `Unsupported` error, never silently misread:
- **Tags:** `!!str`, `!custom` and `%TAG` directives. Convert types after parsing instead.
- **Complex keys:** `? key` and a collection used as a key (`[a, b]: x`). Aliases as keys aren't allowed either.
- **Merge keys:** `<<: *base` (YAML 1.1). A quoted `"<<"` is an ordinary key.

Also not in 0.1:
- `str` writes block style only (no flow style), and doesn't keep comments, anchors or the formatting of a parsed file.
- Aliases are expanded into copies, so a document with many nested aliases (a "billion laughs" document) can grow large.
- A tab can't start a line's indentation in block context, even where YAML would allow it as separation.
- A few rare spec corners aren't handled: anchors on mapping keys, and leading empty lines that are more indented than a block scalar's content.
