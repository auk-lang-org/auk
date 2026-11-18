# Auk

Statically typed and compiled to native code. Braces delimit blocks; no semicolons. A newline ends a statement unless the line ends with an operator, `=`, `=>`, `,` or an open bracket, or the next line starts with `.`, `|>`, `requires`, `ensures` or `{`. Comments: `//`, `/* */`, `///` doc.

## Types
`int` (64-bit, overflow and shifts past 63 trap; `+% -% *% <<` wrap) · `float` · `bool` · `char` `'a'` · `str` (UTF-8; `s[i]` is the i-th char; `s.len()` counts chars) · `[T]` · `{K: V}` · `(A, B)` (`t.0`) · `()` · `T?` (maybe missing) · `T!` (value or `Err`) · `T!E` (value or error enum `E`) · library generics `Set<T>`.
No implicit conversions: `float(n)`, `int(x)`, `str(v)` (`str` of a `[char]` joins it), `int(c)`/`char(n): char?` (code points; chars compare by code point). A plain value converts to `T?`/`T!` where one is expected; `some(v)` and `none` also build a `T?`.
Units: `3.0<m>`, `float<m/s^2>` (no space before `<`). `+ -`, comparisons and calls need equal units; `* /` combine them; plain numbers only scale (`0` fits any). `float(x)` drops a unit; `"{d}"` prints `3.0 m`.
Strings: `"hi {name} {x:.2} {n:>5}"` interpolates any expression; `{{` and `}}` are literal braces. Escapes: `\n \t \r \0 \\ \" \' \u{1F986}`. Slices: `s[a..b]`, `xs[a..b]`. Floats print in the shortest exact form (`2.0`). `r"..."`/`r"""..."""` don't interpolate. Triple-quoted strings drop the first newline and strip the closing line's indentation from every line. `"{e}"` on an `Err` gives its message and causes. Numbers: `1_000`, `0xff`, `1e-9`.
Precedence, tightest first: postfix (`.f()` `[i]` `?` `!` `?.`) > `await` `catch` > unary `- ! ~` > `**` > `* / %` > `+ -` > `<< >>` > `&` > `^` > `|` > `..` > comparisons > `is` > `&&` > `||` > `|>` > `else`. A `?` after a `|>` step applies to the whole pipe so far. `/` and `%` truncate toward zero: `-7 / 2 == -3`, `-7 % 2 == -1`. `+` also concatenates `str` and `[T]`. `x is pat` tests a pattern.
Assignment copies values (copy-on-write); memory is reference-counted.

## Bindings
```
let x = 1            // immutable
var n: int = 0
n += 1
```
A top-level `let` is a module constant. Trailing commas are allowed everywhere.

## Functions
```
fn add(a: int, b: int): int = a + b
fn greet(name: str) { print("hi {name}") }
fn save(t: Todo): ()! uses fs { ... }     // can fail, returns nothing
pub fn area(s: Shape): float { ... }      // pub = visible to other modules
```
The last expression is returned. `return`, `break`, `continue` and `fail(e)` are expressions (`else return 0`). `x.f(a)` and `x |> f(a)` mean `f(x, a)`; don't mix them in one chain. A dot call finds `f` by `x`'s type, then in core.
Overloading by parameter count or first-parameter type: `fn show(i: Item)`, `fn show(o: Order)`.
Closures: `x => x * 2`, `(a, b) => a + b`, `x => { ... }`; one over pairs can unpack them: `xs.enum().map((i, x) => ...)`.
Type arguments are never written at call sites: `let ts: [Todo] = json.decode(s)?`.
A `var` parameter mutates the caller's variable, marked `&` at the call site:
```
fn bump(n: var int) { n += 1 }
bump(&x)
x.bump()             // a dot call needs no &
```

## Clauses and patterns
A clause group is a contiguous run of `fn`s with the same name, parameter count and first-parameter type. Clauses are tried in order and must cover every case.
```
fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)

fn len([], acc: int): int = acc
fn len([_, ..t]: [int], acc: int): int = len(t, acc + 1)   // tail calls become loops

fn grade(n: int): str when n >= 90 = "A"
fn grade(_: int): str = "B"
```
Patterns: `0` `"s"` `'c'` `_` `x` · `Circle(r)` · `(a, b)` · `[]` `[a, b]` `[h, ..t]` `[.., last]` · `User { name, .. }` · `{"k": v}` (extra keys allowed; also matches `Value.Map`) · `"GET " + rest` · `ok(v)` `err(e)` `some(v)` `none`. A bare name matches an in-scope enum variant of that name (`Eof`), else binds.
Guards (`when`) must be pure and can't fail. An optional header line before the clauses carries docs, `pub` or contracts: `pub fn fib(n: int): int`.

## Structs, enums, shapes
```
struct Point { x: float, y: float }
let p = Point { x: 1.0, y: 2.0 }
let q = Point { x: 3.0, ..p }   // ..p comes last
let r = Point { x, y }

enum Shape { Circle(r: float), Rect(w: float, h: float) }
let s = Circle(2.0)

shape Area { fn area(self): float }      // structural: any type with area() fits
fn total(xs: [Area]): float = ...        // every item has the same type
fn draw(xs: [any Area]) { ... }          // items can differ (dynamic dispatch)
fn max(a: Ord, b: Ord): Ord = if a > b { a } else { b }   // same shape name = same type
fn pair<A: Show, B: Show>(a: A, b: B): str = a.show() + b.show()
```
Built-in shapes: `Show { fn show(self): str }`, `Ord { fn cmp(self, o: Self): int }` (negative, 0 or positive), `Eq { fn eq(self, o: Self): bool }`, `Data` (anything with `to_value`/`from_value`: primitives, lists, maps, `T?`, structs, enums). `sort min max <` need `Ord`.
A `pub struct`'s fields are public unless their type is private to the module.
Define `add sub mul div mod eq cmp` and `+ - * / % == <` work. `==` is automatic for structs, enums and tuples.

## Control flow
```
if a { } else if b { } else { }       // if, match and loop are expressions
match s {
  Circle(r) => 3.14 * r * r
  Rect(w, h) when w == h => w * w
  Rect(w, h) => w * h
}
for i in 0..n { }        // ..= includes the end
for x in xs { }
for c in s.chars() { }   // a str is not iterable
for i, (a, b) in pairs { }   // index, pattern
for k, v in map { }
while c { }
let v = loop { if done() { break 42 } }
```
Match arms are separated by newlines or commas. A struct literal or `else` inside an `if`/`while`/`for`/`match` head needs parentheses.

## Errors and optionals
```
fn load(path: str): Config! uses fs {
  let text = fs.read(path)?          // ? passes the error (or missing value) up
  parse(text)?
}
let c = load("a.toml") else e => default()   // handle the error
let n = int.parse(s) else 0
m[k] = (m.get(k) else 0) + 1    // `else` binds loosest; `??` is only a hole
fail("bad input")                              // return an Err from a T! fn

enum ParseErr { BadToken(at: int), Eof }
fn parse(s: str): Ast!ParseErr { ... }         // ?/fail() make it an Err that still matches err(BadToken(at))

fn find(xs: [User], id: int): User? = xs.find(u => u.id == id)
let name = find(us, 1)?.name else "nobody"
let [h, ..t] = xs else { return 0 }            // a pattern that might not match
let nums = strs.map(s => int.parse(s))?        // [T!]? gives [T], or the first error
let m = xs.max()!                              // unwrap or panic
```
`x?.f`, `x?.f()` and `x?.0` (a tuple element) are optional chaining on `T?` only; each step of a chain needs its own `?.` (`xs.first()?.1?.len()`). To pass up an error and then call, write `(x?).f()`.
Maps keep insertion order. `m[k]` panics if the key is missing; `m[k] = v` inserts or replaces; `m.get(k)`/`xs.get(i)` return `V?`/`T?`.

## Effects
A function touching the outside world declares it: `uses fs, net, time, rand, env, proc, audio_out, gui, ffi`. Without `uses` it is pure; `print` is always allowed.

## Async
```
async fn get(url: str): Resp! uses net { ... }
let page = await get(u)?                  // (await get(u))?
let (a, b) = await (get(u1), get(u2))     // runs concurrently
let all = await urls.map(u => get(u))     // [Resp!]
let r = catch handle(req, &db)            // Resp!: a panic inside becomes an Err
let x = catch { parse(s)? + xs[i] } else 0
var ts: [Task<Resp!>] = [get(u1), get(u2)]
let (i, r) = await any ts                 // first to finish; r: Resp!, a panic is an Err
ts[1].cancel()                            // it panics "cancelled" at its next loop or blocking call; ts[0].done(): bool; reloads(): int counts `auk run --live` swaps
let c: Chan<Job> = chan()                 // c.send(j); c.recv(): Job? (none once closed); c.recv_for(ms); c.close(); for j in c
```
An `async fn` call must be awaited, stored or returned; outside an `async fn`, `await` blocks. A task's panic is raised again at its `await`; a task that panics cancels the tasks it started. Tasks share nothing: arguments, results and messages are copied (so no `var` parameter on a started task), and a crashed task's memory is freed. `catch` may change the variables it uses; `return` can't leave it. Supervisors: package `sup`.

## Contracts, holes, tests, debugging
```
fn isqrt(n: int): int
  requires n >= 0                  // checked in every build
  ensures result * result <= n     // checked in debug and test builds; old(x) = x on entry
{ ?? }                             // a hole: type-checks, panics if reached, blocks `auk build`

test "isqrt" { assert isqrt(17) == 4 }   // tests may use ? and fail(); an error fails the test
peek x * 2         // prints [file:line] x * 2 = 84, returns the value
imprint T = table()   // computed at compile time (pure fns only)
```
`assert (a, b) == (1, 2)` checks the whole comparison.
To see values without editing code: `auk debug -b f.auk:12 -p x,y f.auk` runs to each breakpoint (`file:line` or a function, `-b "f.auk:12 if n > 3"`) and panic and prints the locals and stack there; `-p`/`-e` take Auk expressions too (`-e "xs.len()"`; `--json`, `--timeout S`).

## C functions
A package whose raft.toml has `effects = ["ffi"]` binds C with a C prototype; every call needs `uses ffi`. C libraries go in raft.toml `[link] libs = ["sqlite3"]` (libc needs none).
```
extern type Db = "sqlite3 *"                     // an opaque C pointer type; types don't mix
extern fn open(path: str, db: var Db?, flags: int, vfs: str?): int =
  "int sqlite3_open_v2(const char *, sqlite3 **, int, const char *)"
extern fn print_module(m: Module): str = "char *LLVMPrintModuleToString(LLVMModuleRef) +free(LLVMDisposeMessage)"
```
C integers ↔ `int` (truncated going in, extended coming out) · `bool` · `float`/`double` ↔ `float` · `const char *` ↔ `str` (a result is copied; `str?` when it may be NULL; `+free(fn)` frees an owned `char *` after copying) · other pointers ↔ `ffi.Ptr` or an `extern type`, `T?` when NULL is possible · `T *` ↔ a list `[T]` (copied in; `var [T]` copies back; `[int]` ↔ `void *` is bytes) · a `var` parameter is an out-parameter (`int *`, `T **`, `char **` as `var str?`) · `void` ↔ `()`. No varargs, structs by value or callbacks. `ffi`: `Ptr null is_null addr ptr(n) offset alloc free read_u8/i32/i64/f64/ptr write_* cstr bytes(p, n) from_bytes`. A crash in C can't be caught.

## Modules, packages, program entry
A file is a module, a folder a package; refer to anything by path, no imports: `geo.area(s)`, `json.parse(t)`. A local named like a project module or dependency is an error; one named like a core module shadows it (`core.env` still reaches core). `regex(p)` is `regex.regex(p)`. In a package its own name is its root (`http.Resp`). Add dependencies with `raft add http`.
```
fn main(args: [str]): int! uses fs {    // the parameters and return type are optional
  run(args[1])?                          // an Err prints and exits with 1
  0
}
```

## Core library (always available)
`fs`: `read write append lines read_bytes write_bytes exists is_dir list mkdir remove rename temp_dir` · `net.tcp(host, port): net.Conn!`, `net.tls` (cert-verified): `read(max): [int]! write(bytes) close()` · `net.listen(host, port): net.Listener!` (port 0: any): `accept(): Conn! port() close()` · `time.now()` (ms) `sleep(ms)` · `rand`: `int(lo, hi) float shuffle choice seed(n)`, secure `bytes(n)` · `env`: `get(k): str? args`, stdin `read_line(): str? read_all lines` · `proc`: `run(cmd, args): str! exit(code)` · `eprint` (stderr)
`enum Value { Null, Bool(b), Int(i), Float(f), Str(s), List(xs), Map(m) }`: structs and enums get `to_value(x)` and `from_value(v): T!`.
Collections: `len push pop(): T? insert remove contains get first last min max: T? map filter flat_map reduce(init, f) find(pred): T? find_index: int? take skip take_while any all sum reverse chunks(n) windows(n) counts(): {T: int} group_by(key): {K: [T]} unique zip enum join(sep)` · `sort sort_by(key)`: stable sorted copies; tuples and lists compare element by element: `sort_by(p => (-p.n, p.name))` · maps: `remove(k): V? keys values entries`.
Strings: `len split(sep = whitespace) trim lines starts_with ends_with replace find(sub): int? (char index) contains upper lower repeat(n) chars bytes` · chars: `is_digit is_alpha is_space upper lower` (ASCII) · `int.parse float.parse str.from_utf8`. Floats: `sqrt abs floor ceil round sin cos tan asin acos atan atan2(y, x) exp ln log10 log2`, `x.bits()`/`float.from_bits(n)` (and `bits32`/`from_bits32` for f32), `float.pi` `float.e`.
`gui` (windows, in a separate window process; macOS so far): `open(title, w, h): int! present(win, f)! present_rect(win, f, x, y, w, h)! present_rects(win, f, [x, y, w, h, ...])! next_event(win, ms): gui.Event? width height scale close` · `pixels` (pure): `pixels.Frame`, 32-bit pixels `0xTTRRGGBB` where the top byte is transparency (0 opaque, so `0xRRGGBB` is opaque; `CLEAR` = `0xff000000`), copy-on-write like any value: `frame(w, h, color) from_list(w, h, px) to_list width height get set fill blend blit composite blit_mask argb(a, r, g, b) alpha(c)`.
Prefer these to hand-written loops. Packages (raft): `json csv regex cli http encoding hash datetime url toml log uuid num text glob compress yaml xml sup splash audio graphics term template markdown`.
