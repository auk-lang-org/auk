# Core library reference

Everything on this page is available in every program, with nothing to install or import.
Functions are shown as they are called; remember that `x.f(a)` and `f(x, a)` are the same
call.

Anything not here lives in a package: see the [package catalog](packages.md).

## Console and conversions

| | |
|---|---|
| `print(x)` | write `x` and a newline to stdout; no effect needed |
| `eprint(x)` | the same, to stderr |
| `str(x)` | the text of any value; `str` of a `[char]` joins it |
| `int(x)` | from a `float` (truncating) or a `char` (its code point) |
| `float(n)` | from an `int`; also drops a unit of measure |
| `char(n): char?` | from a code point |
| `int.parse(s): int!`, `int.parse(s, radix)` | |
| `float.parse(s): float!` | |
| `str.from_utf8(bytes): str!` | |
| `some(v)`, `none` | build a `T?` |
| `fail(e)` | return an error from the current function |
| `min(a, b)`, `max(a, b)` | of any two `Ord` values |

## Strings

Indexes and lengths count characters, not bytes.

| | |
|---|---|
| `s.len()`, `s.byte_len()` | |
| `s[i]`, `s[a..b]` | a `char`, a slice |
| `s.chars(): [char]`, `s.bytes(): [int]` | |
| `s.split()`, `s.split(sep)` | on whitespace, or on a separator |
| `s.lines()` | |
| `s.trim()`, `trim_start()`, `trim_end()` | |
| `s.starts_with(p)`, `ends_with(p)`, `contains(x)` | `contains` takes a `str` or a `char` |
| `s.strip_prefix(p): str?`, `strip_suffix(p): str?` | |
| `s.find(sub): int?` | the character index of the first match |
| `s.replace(from, to)` | every occurrence |
| `s.upper()`, `s.lower()`, `s.repeat(n)` | |
| `a + b` | concatenation |

Characters: `c.is_digit()`, `c.is_digit(radix)`, `c.is_alpha()`, `c.is_space()`, `c.upper()`,
`c.lower()` (ASCII rules). Characters compare by code point.

Format specs inside `{}`: `{x:.2}` precision, `{x:>8}` and `{x:<8}` alignment in a width,
`{n:08}` zero padding, `{n:x}` `{n:X}` `{n:o}` `{n:b}` an `int` in hex, octal or binary.

## Numbers

| | |
|---|---|
| `x.abs()` | `int` or `float` |
| `x.sqrt()`, `floor()`, `ceil()`, `round()` | `float` |
| `sin cos tan asin acos atan`, `atan2(y, x)` | |
| `exp`, `ln`, `log10`, `log2` | |
| `float.pi`, `float.e` | |
| `x.bits()`, `float.from_bits(n)` | the IEEE 754 bit pattern; `bits32` / `from_bits32` for 32-bit |
| `a ** b` | power |
| `+%` `-%` `*%` | wrapping `int` arithmetic (the plain operators panic on overflow) |

## Lists

Functions that "change" a list take it as a `var` and are called on a variable; everything
else returns a new value.

| in place | |
|---|---|
| `xs.push(x)` | |
| `xs.pop(): T?` | remove and return the last item |
| `xs.insert(i, x)` | |
| `xs.remove(i): T` | |
| `xs[i] = x` | |

| reading | |
|---|---|
| `xs.len()` | |
| `xs[i]`, `xs[a..b]` | panics when out of range |
| `xs.get(i): T?`, `first(): T?`, `last(): T?` | |
| `xs.contains(x)` | |
| `xs.find(pred): T?`, `find_index(pred): int?` | |
| `xs.any(pred)`, `xs.all(pred)` | |
| `xs.min(): T?`, `xs.max(): T?` | |
| `xs.sum()` | `[int]` or `[float]` |
| `xs.join(sep): str` | |

| building new lists | |
|---|---|
| `xs.map(f)`, `filter(pred)`, `flat_map(f)` | |
| `xs.reduce(init, (acc, x) => ...)` | |
| `xs.take(n)`, `skip(n)`, `take_while(pred)` | |
| `xs.reverse()` | |
| `xs.sort()` | a sorted copy; stable; needs `Ord` |
| `xs.sort_by(key)` | by a key; a tuple key sorts by several fields |
| `xs.unique()` | keeps the first of each |
| `xs.enum(): [(int, T)]` | pairs each item with its index |
| `xs.zip(ys): [(A, B)]` | |
| `xs.chunks(n)`, `windows(n): [[T]]` | |
| `xs.counts(): {T: int}` | how many of each |
| `xs.group_by(key): {K: [T]}` | groups in first-seen order |
| `a + b` | concatenation |

Ranges are lists too: `(0..5).map(i => i * i)`.

```auk
struct Sale { region: str, amount: int }

fn main() {
  let sales = [
    Sale { region: "north", amount: 120 },
    Sale { region: "south", amount: 80 },
    Sale { region: "north", amount: 50 },
  ]
  for region, group in sales.group_by(s => s.region) {
    print("{region}: {group.map(s => s.amount).sum()}")   // north: 170, then south: 80
  }
  print(sales.sort_by(s => -s.amount).first()?.region else "none")   // north
  print([1, 2, 3, 4, 5].windows(2).map(w => w[1] - w[0]))            // [1, 1, 1, 1]
  print(["a", "b"].zip([1, 2]))                                      // [("a", 1), ("b", 2)]
}
```

## Maps

Maps keep insertion order, and iterate in it.

| | |
|---|---|
| `{"a": 1, "b": 2}` | a literal |
| `m[k]` | panics when the key is missing |
| `m[k] = v` | insert or replace |
| `m.get(k): V?` | |
| `m.contains(k)` | |
| `m.remove(k): V?` | |
| `m.len()` | |
| `m.keys()`, `values()`, `entries(): [(K, V)]` | |
| `for k, v in m { }` | |

The counting idiom is `m[k] = (m.get(k) else 0) + 1`, though `xs.counts()` usually does it for
you.

## Sets

`set(xs)` builds a `Set<T>`. `s.contains(x)`, `s.insert(x)`, `s.remove(x): bool`, `s.len()`,
`s.to_list()`.

## Value

```auk
enum Value { Null, Bool(b: bool), Int(i: int), Float(f: float), Str(s: str), List(xs: [Value]), Map(m: {str: Value}) }
```

The neutral data tree that format packages read and write. `to_value(x)` and
`from_value(v): T!` are derived for every struct and enum: a struct becomes a `Map` keyed by
field name, and an enum variant a `Map` with a `"tag"` (or just a `Str` when it has no
fields).

## Tasks and channels

| | |
|---|---|
| `await t`, `await (a, b)`, `await [tasks]`, `await any ts` | see [Concurrency](../language/concurrency.md) |
| `t.done(): bool`, `t.cancel()` | |
| `chan(): Chan<T>` | |
| `c.send(x)`, `c.recv(): T?`, `c.recv_for(ms): T?`, `c.close()` | |
| `reloads(): int` | how many `auk run --live` swaps have happened |

## Modules that need an effect

### `fs` (`uses fs`)

| | |
|---|---|
| `fs.read(path): str!`, `fs.write(path, text): ()!`, `fs.append(path, text): ()!` | whole files, as text |
| `fs.lines(path): [str]!` | |
| `fs.read_bytes(path): [int]!`, `fs.write_bytes(path, bytes): ()!` | bytes are ints 0 to 255 |
| `fs.exists(path)`, `fs.is_dir(path)` | |
| `fs.list(dir): [str]!` | names, sorted |
| `fs.mkdir(path): ()!` | creates parents too |
| `fs.remove(path): ()!` | a file or an empty directory |
| `fs.rename(from, to): ()!` | |
| `fs.temp_dir(): str!` | a new private directory |

### `env` (`uses env`)

| | |
|---|---|
| `env.get(name): str?` | an environment variable |
| `env.args(): [str]` | the same list `main(args)` receives |
| `env.read_line(): str?` | a line of stdin; `none` at the end |
| `env.read_all(): str!`, `env.lines(): [str]` | all of stdin |
| `env.is_terminal(fd): bool`, `env.columns(): int?` | |

### `time` (`uses time`)

`time.now(): int` is milliseconds since the Unix epoch; `time.sleep(ms)`. For calendars and
formatting, use the `datetime` package.

### `rand` (`uses rand`)

`rand.int(lo, hi)`, `rand.float()`, `rand.shuffle(xs)`, `rand.choice(xs): T?` use a fast
generator that `rand.seed(n)` makes repeatable. `rand.bytes(n): [int]` comes from the
operating system's cryptographic generator and ignores the seed.

### `proc` (`uses proc`)

`proc.run(cmd, args): str!` runs a program and returns its output. `proc.exit(code)` ends this
one.

### `net` (`uses net`)

| | |
|---|---|
| `net.tcp(host, port): net.Conn!` | |
| `net.tls(host, port): net.Conn!` | always verifies the certificate against the system's trust store; this cannot be turned off |
| `c.read(max): [int]!` | bytes; an empty list means the peer closed |
| `c.write(bytes): ()!`, `c.close()` | |
| `net.listen(host, port): net.Listener!` | `""` is every interface; port 0 picks a free one |
| `l.accept(): net.Conn!`, `l.port()`, `l.close()` | `accept` blocks only the calling task |

Text and bytes convert with `s.bytes()` and `str.from_utf8(bytes)`. For HTTP, use the `http`
package.

### `gui`, `pixels`, `audio_out`

`gui` opens windows and presents frames (macOS only so far), `pixels` is the pure frame type
it draws from, and `audio_out` plays samples. Most programs use them through the `graphics`
and `audio` packages.

### `ffi`

See [Calling C](../language/c-interop.md).
