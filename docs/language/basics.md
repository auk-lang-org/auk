# Basics: values, bindings and control flow

Auk is statically typed and compiled, with type inference inside functions. Braces delimit
blocks and a newline ends a statement; there are no semicolons.

## Bindings

```auk
let answer = 42          // immutable
var count = 0            // mutable
count += 1
let ratio: float = 0.5   // an annotation is optional
var (a, b) = (1, 2)
(a, b) = (b, a)          // swap: the right side is computed first
print("{answer} {count} {ratio} {a} {b}")   // 42 1 0.5 2 1
```

A `let` at the top level of a file is a module constant. Trailing commas are allowed
everywhere a comma is.

A statement continues onto the next line when the line ends with an operator, `=`, `=>`, `,`
or an open bracket, or when the next line starts with `.`, `|>` or `{`:

```auk
let total = [1, 2, 3]
  .map(x => x * 2)
  .sum()
print(total)   // 12
```

Comments are `//` to the end of the line and `/* ... */`. A `///` comment documents the item
below it.

## The built-in types

| type | values | notes |
|---|---|---|
| `int` | `42`, `1_000`, `0xff` | 64-bit signed; overflow is a panic, not a wrap |
| `float` | `2.0`, `1e-9` | 64-bit; prints in the shortest exact form (`2.0`, `0.1`) |
| `bool` | `true`, `false` | |
| `char` | `'a'`, `'\n'`, `'\u{1F986}'` | one Unicode code point |
| `str` | `"hi"` | immutable UTF-8 text, indexed by character |
| `[T]` | `[1, 2, 3]` | list |
| `{K: V}` | `{"a": 1}` | map; keeps insertion order |
| `(A, B)` | `(1, "x")` | tuple; `t.0`, `t.1` |
| `()` | `()` | "nothing"; what a function with no result returns |
| `T?` | `some(3)`, `none` | a value that may be missing |
| `T!` | a value, or an error | see [Errors](errors.md) |

There are no implicit conversions, not even from `int` to `float`. Convert by calling the
type:

```auk
let n = 7
print(float(n) / 2.0)      // 3.5
print(int(9.99))           // 9: truncates toward zero
print(str(n) + "!")        // 7!
print(int('a'))            // 97
print(char(98))            // some('b'): not every int is a code point
print(int.parse("12"))     // ok(12)
print(float.parse("x"))    // an error value; see Errors
```

## Numbers

```auk
print(7 / 2)        // 3: int division truncates toward zero
print(-7 / 2)       // -3
print(-7 % 2)       // -1
print(2 ** 10)      // 1024
print(7.0 / 2.0)    // 3.5
print(0xff & 0x0f)  // 15: bitwise & | ^ ~ << >>
print(2.0.sqrt())   // 1.4142135623730951
```

`int` arithmetic is checked. `+`, `-` and `*` panic on overflow, as does a shift by more
than 63. When you want wrapping (hashes, checksums), say so with `+%`, `-%` and `*%`.

A number can carry a unit of measure, such as `9.81<m/s^2>`, which the compiler checks and
then erases. See [Units of measure](units.md).

## Strings

Strings interpolate any expression inside `{}`:

```auk
let name = "auk"
let pi = 3.14159
print("hello, {name.upper()}")            // hello, AUK
print("{pi:.2}")                          // 3.14: two decimals
print("[{name:>6}] [{name:<6}]")          // [   auk] [auk   ]
print("{255:x} {255:08b} {7:03}")         // ff 11111111 007
print("literal braces: {{ and }}")        // literal braces: { and }
```

A string is a sequence of characters, not bytes. `s.len()` counts characters, `s[i]` is the
`i`-th character, and `s[a..b]` is a slice:

```auk
let s = "naïve 🦆"
print(s.len())          // 7
print(s[2])             // ï
print(s[0..5])          // naïve
print(s.byte_len())     // 11
for c in "hi".chars() { print(c) }   // a str is not iterable itself: say chars() or bytes()
```

`+` concatenates. Strings are immutable, so "changing" one builds a new one (`s += "x"` is
efficient: it appends in place when nothing else holds the string).

Raw strings don't interpolate or process escapes, and triple-quoted strings span lines. A
triple-quoted string drops its first newline and strips the closing line's indentation from
every line:

```auk
print(r"C:\dir\{not interpolated}")
let text = """
    first line
      indented two
    """
print(text)
```

The second `print` writes `first line`, then `  indented two`.

Common string functions: `split` (on whitespace, or `split(",")`), `trim`, `lines`,
`starts_with`, `ends_with`, `strip_prefix`, `contains`, `find`, `replace`, `upper`, `lower`,
`repeat`. The full list is in the [core library reference](../reference/core.md).

## Lists and maps

```auk
var xs = [5, 3, 8]
xs.push(1)
xs[0] = 50
print(xs)                 // [50, 3, 8, 1]
print(xs.len())           // 4
print(xs[1..3])           // [3, 8]
print(xs.get(10))         // none: get never panics; xs[10] would
print(xs + [0])           // [50, 3, 8, 1, 0]
print(xs.sort())          // [1, 3, 8, 50]: a sorted copy; xs is unchanged

var stock = {"apple": 3, "pear": 0}
stock["fig"] = 12         // insert or replace
stock["apple"] += 1
print(stock.get("kiwi") else 0)    // 0
print(stock.keys())       // ["apple", "pear", "fig"]: insertion order
let empty: [str] = []     // an empty literal needs a type from somewhere
print(empty.len())        // 0
```

Indexing out of range, and `m[k]` for a missing key, panic. Use `get` when the element might
not be there; it returns an optional.

Lists come with the usual functional toolkit, and closures are written `x => ...`:

```auk
let xs = [5, 3, 8, 1, 9, 2]
print(xs.filter(x => x % 2 == 1).map(x => x * x))   // [25, 9, 1, 81]
print(xs.reduce(0, (acc, x) => acc + x))            // 28
print(xs.sort().take(3).join(" < "))                // 1 < 2 < 3
print(xs.max())                                     // some(9)
print(["b", "a", "b"].counts())                     // {"b": 2, "a": 1}
```

Prefer these to hand-written loops: they are shorter, and they say what the loop is for.

## Values, not references

Every value in Auk behaves as a copy. Assigning a list, passing it to a function or putting
it in a struct never lets someone else change your copy:

```auk
var a = [1, 2, 3]
var b = a
b.push(4)
print(a)   // [1, 2, 3]
print(b)   // [1, 2, 3, 4]
```

This is cheap: values are reference-counted and copied only when a shared one is written to
(copy-on-write). There is no garbage collector, no `null`, and no aliasing to reason about. A
function that should change its caller's variable says so with a
[`var` parameter](functions.md#var-parameters).

## Control flow

`if`, `match` and `loop` are expressions, so they produce values:

```auk
let n = 7
let size = if n > 5 { "big" } else { "small" }
print(size)   // big

for i in 0..3 { print(i) }          // 0 1 2
for i in 0..=3 { print(i) }         // 0 1 2 3: ..= includes the end
for x in ["a", "b"] { print(x) }
for i, x in ["a", "b"] { print("{i}: {x}") }      // with the index
for k, v in {"one": 1, "two": 2} { print("{k} = {v}") }

var i = 0
while i < 3 { i += 1 }

let first_big = loop {              // loop runs until a break; break can carry the value
  i += 1
  if i * i > 50 { break i }
}
print(first_big)   // 8
```

`break`, `continue` and `return` work as you expect. `match` picks the first arm whose pattern
fits, and the compiler checks that the arms cover every case:

```auk
let code = 404
let text = match code {
  200 => "ok"
  301 | 302 => "moved"
  n when n >= 500 => "server error"
  _ => "other"
}
print(text)   // other
```

Patterns do much more than match numbers. They are covered with
[functions and clauses](functions.md#patterns).

## Operators, tightest first

| | |
|---|---|
| postfix | `.f()` `[i]` `?` `!` `?.` |
| prefix keywords | `await` `catch` |
| unary | `-` `!` `~` |
| power | `**` |
| multiplicative | `*` `/` `%` |
| additive | `+` `-` |
| shifts | `<<` `>>` |
| bitwise | `&` then `^` then `\|` |
| range | `..` `..=` |
| comparison | `==` `!=` `<` `<=` `>` `>=` |
| pattern test | `is` |
| logical | `&&` then `\|\|` |
| pipe | `\|>` |
| fallback | `else` |

Comparisons don't chain (`a < b < c` is an error), and a bitwise operator next to a comparison
needs parentheses. `==` works on every built-in type and, automatically, on your structs,
enums and tuples.

Next: [Functions, clauses and patterns](functions.md).
