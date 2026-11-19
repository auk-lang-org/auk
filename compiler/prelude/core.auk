/// The core library: always in scope, in every module, without a path (`core.x` still works when
/// a local name shadows `x`). Each `extern fn` binds an Auk signature to a C function of the
/// runtime (runtime/src). A symbol that starts with `@` is a compiler intrinsic instead (see
/// `typed::Intrinsic`), and a trailing ` +loc` means the C function takes the call site's
/// "file:line:col" as an extra last argument (for its panic message).
///
/// Externs over generic containers follow the runtime's element-pointer convention: an element
/// argument is passed by address (`const void *`), a `T?` result comes back through
/// `bool f(.., void *out)`, and a `var` container parameter is a `AukArr **` / `AukMap **`.

// ---- built-in types and shapes ----

/// An error: a message, an optional cause and an optional typed payload. `"{e}"` prints the
/// message followed by its causes.
pub extern type Err = "AukErr *"

/// The neutral data tree that format packages (`json`, `csv`) convert text to and from.
pub enum Value { Null, Bool(b: bool), Int(i: int), Float(f: float), Str(s: str), List(xs: [Value]), Map(m: {str: Value}) }

/// Anything that can be printed and interpolated. Automatic for every type except closures and
/// tasks (structs and enums show as `Point { x: 1.0, y: 2.0 }` / `Circle(2.0)`).
pub shape Show { fn show(self): str }
/// A total order: negative, 0 or positive. Automatic for int, float, char, str, bool, and lists
/// and tuples of `Ord` types; `sort`, `min`, `max` and `<` need it.
pub shape Ord { fn cmp(self, o: Self): int }
/// Equality. Automatic for every type except closures, tasks, `Err` and `net.Conn`.
pub shape Eq { fn eq(self, o: Self): bool }
/// Convertible to and from `Value` with `to_value(x)` and `from_value(v): T!`. Automatic for
/// primitives, `Value`, lists, `{str: T}` maps, `T?`, structs and enums whose fields are `Data`.
pub shape Data { fn to_value(self): Value }

// ---- intrinsics: generic operations the compiler implements per type ----

/// The `Show` text of any value (`show(x)`, `x.show()`).
pub extern fn show<T: Show>(x: T): str = "@show"
/// `a == b` for any `Eq` type.
pub extern fn eq<T: Eq>(a: T, b: T): bool = "@eq"
/// Three-way comparison for any `Ord` type.
pub extern fn cmp<T: Ord>(a: T, b: T): int = "@cmp"
/// The derived (or user-defined) conversion to `Value`.
pub extern fn to_value<T: Data>(x: T): Value = "@to_value"
/// The derived conversion from `Value`; `T` comes from the expected type
/// (`let t: Todo = from_value(v)?`). An `Int` fills a `float` field.
pub extern fn from_value<T: Data>(v: Value): T! = "@from_value"
/// `some(v)` builds a `T?` (so does a plain value where a `T?` is expected; `none` is the empty one).
pub extern fn some<T>(x: T): T? = "@some"
/// `fail(e)` returns an error from the enclosing `T!`/`T!E` function (or test). `e` is a `str`
/// message, an `Err`, or a value of the function's error enum (which converts to `Err` in a `T!`
/// function). Its type is `never`.
pub extern fn fail<E>(e: E) = "@fail"
/// The text of an error and its causes.
pub extern fn show(e: Err): str = "auk_err_show"

// ---- conversions ----

pub extern fn float(n: int): float = "@int_to_float"
/// `float(x)` of a `float<unit>` drops the unit (the explicit way to get a plain number).
pub fn float(x: float): float = x
/// Truncates toward zero; panics on NaN or out of range.
pub extern fn int(x: float): int = "auk_float_to_int +loc"
/// `int(n)` of an `int<unit>` drops the unit.
pub fn int(n: int): int = n
/// The code point of a char.
pub extern fn int(c: char): int = "@char_to_int"
/// The char with code point `n`, or none for surrogates and values past U+10FFFF.
pub extern fn char(n: int): char? = "auk_char_from_int"
/// `str` of a `[char]` joins the chars.
pub extern fn str(cs: [char]): str = "auk_str_from_chars"
/// The `Show` text of any other value.
pub fn str<T: Show>(x: T): str = x.show()

/// Print the `Show` text of `x` and a line break. Always allowed (no effect needed).
pub fn print<T: Show>(x: T) { print_str(x.show()) }
extern fn print_str(s: str) = "auk_print"
/// `print` to stderr. Always allowed.
pub fn eprint<T: Show>(x: T) { eprint_str(x.show()) }
extern fn eprint_str(s: str) = "auk_eprint"

// ---- strings ----

/// The number of chars.
pub extern fn len(s: str): int = "auk_str_len"
/// Split on runs of whitespace (no empty pieces).
pub extern fn split(s: str): [str] = "auk_str_split_ws"
/// Split on every `sep`: `"a,,b".split(",")` is `["a", "", "b"]`.
pub extern fn split(s: str, sep: str): [str] = "auk_str_split"
pub extern fn trim(s: str): str = "auk_str_trim"
/// Without the leading whitespace.
pub extern fn trim_start(s: str): str = "auk_str_trim_start"
/// Without the trailing whitespace.
pub extern fn trim_end(s: str): str = "auk_str_trim_end"
/// Split on line breaks (a trailing `\r` is dropped; no final empty line).
pub extern fn lines(s: str): [str] = "auk_str_lines"
pub extern fn starts_with(s: str, prefix: str): bool = "auk_str_starts_with"
pub extern fn ends_with(s: str, suffix: str): bool = "auk_str_ends_with"
/// The rest of `s` after `prefix`, or none if `s` doesn't start with it.
pub fn strip_prefix(s: str, prefix: str): str? = if s.starts_with(prefix) { s[prefix.len()..s.len()] } else { none }
/// `s` without `suffix` at its end, or none if it doesn't end with it.
pub fn strip_suffix(s: str, suffix: str): str? = if s.ends_with(suffix) { s[0..s.len() - suffix.len()] } else { none }
pub extern fn replace(s: str, from: str, to: str): str = "auk_str_replace"
/// The char index of the first occurrence of `sub`.
pub extern fn find(s: str, sub: str): int? = "auk_str_find"
/// Does `s` contain `x` (a `str` or a `char`)?
pub fn contains<T: Needle>(s: str, x: T): bool = x.found_in(s)
extern fn contains_str(s: str, sub: str): bool = "auk_str_contains"
extern fn contains_char(s: str, c: char): bool = "auk_str_contains_char"
pub extern fn upper(s: str): str = "auk_str_upper"
pub extern fn lower(s: str): str = "auk_str_lower"
pub extern fn chars(s: str): [char] = "auk_str_chars"
/// The UTF-8 bytes, as ints 0..255.
pub extern fn bytes(s: str): [int] = "auk_str_bytes"
/// The number of UTF-8 bytes (`s.bytes().len()` without the copy).
pub extern fn byte_len(s: str): int = "auk_str_byte_len"
pub extern fn repeat(s: str, n: int): str = "auk_str_repeat +loc"

/// What `contains` on a `str` looks for.
shape Needle { fn found_in(self, s: str): bool }
fn found_in(sub: str, s: str): bool = contains_str(s, sub)
fn found_in(c: char, s: str): bool = contains_char(s, c)

pub extern fn is_digit(c: char): bool = "auk_char_is_digit"
/// Is `c` a digit in base `radix` (2 to 36; letters in either case past 9)?
pub fn is_digit(c: char, radix: int): bool {
  let d = if c >= '0' && c <= '9' {
    int(c) - int('0')
  } else if c >= 'a' && c <= 'z' {
    int(c) - int('a') + 10
  } else if c >= 'A' && c <= 'Z' {
    int(c) - int('A') + 10
  } else {
    return false
  }
  d < radix
}
pub extern fn is_alpha(c: char): bool = "auk_char_is_alpha"
pub extern fn is_space(c: char): bool = "auk_char_is_space"
pub extern fn upper(c: char): char = "auk_char_upper"
pub extern fn lower(c: char): char = "auk_char_lower"

// ---- tasks ----

/// Stop a task: it panics "cancelled" at its next loop iteration or blocking call (sleep, await,
/// net I/O), and no `catch` inside it can hold that panic. Awaiting it raises the panic (or gives
/// it as an `Err` from `await any`). No effect on a finished task.
pub extern fn cancel<T>(t: Task<T>) = "auk_task_cancel"

/// Has the task finished (its result, error or panic is in, so `await` won't wait)?
pub extern fn done<T>(t: Task<T>): bool = "auk_task_done"

/// How many times `auk run --live` has swapped new code into this program (0 when not live):
/// watch it to react to a reload.
pub extern fn reloads(): int = "auk_live_reloads"

// ---- channels ----

/// The runtime side of a channel, shared by every copy of its `Chan`.
pub extern type ChanRef = "AukChan *"

/// A queue of `T` messages between tasks (unbounded). Each message is copied, so a sender and
/// a receiver never share data. Pass the channel to tasks as an argument; `for x in c` receives
/// until it is closed.
pub struct Chan<T> { r: ChanRef, proto: [T] }

extern fn chan_new<T>(proto: [T]): ChanRef = "auk_chan_new"
extern fn chan_send<T>(r: ChanRef, x: T) = "auk_chan_send +loc"
extern fn chan_recv<T>(r: ChanRef): T? = "auk_chan_recv"
extern fn chan_recv_for<T>(r: ChanRef, ms: int): T? = "auk_chan_recv_for"
extern fn chan_close(r: ChanRef) = "auk_chan_close"

/// A new channel; `T` comes from the expected type: `let c: Chan<Job> = chan()`.
pub fn chan<T>(): Chan<T> {
  let proto: [T] = []
  Chan { r: chan_new(proto), proto }
}

/// Queue a copy of `x`. Panics if the channel is closed.
pub fn send<T>(c: Chan<T>, x: T) = chan_send(c.r, x)

/// Wait for the next message: none once the channel is closed and empty.
pub fn recv<T>(c: Chan<T>): T? = chan_recv(c.r)

/// `recv`, but give up after `ms` milliseconds: none if nothing came in time (or the channel is
/// closed and empty). Waiting on a task that might never answer: `reply.recv_for(5000) else ...`.
pub fn recv_for<T>(c: Chan<T>, ms: int): T? = chan_recv_for(c.r, ms)

/// No more messages: receivers get what is queued, then none.
pub fn close<T>(c: Chan<T>) = chan_close(c.r)

// ---- numbers ----

pub extern fn sqrt(x: float): float = "auk_fsqrt"
pub extern fn abs(x: float): float = "auk_fabs"
pub extern fn abs(n: int): int = "auk_int_abs +loc"
pub extern fn floor(x: float): float = "auk_ffloor"
pub extern fn ceil(x: float): float = "auk_fceil"
/// Rounds half away from zero.
pub extern fn round(x: float): float = "auk_fround"
pub extern fn sin(x: float): float = "auk_fsin"
pub extern fn cos(x: float): float = "auk_fcos"
pub extern fn tan(x: float): float = "auk_ftan"
pub extern fn asin(x: float): float = "auk_fasin"
pub extern fn acos(x: float): float = "auk_facos"
pub extern fn atan(x: float): float = "auk_fatan"
/// The angle of the point (x, y): `atan2(y, x)`, in -pi..pi.
pub extern fn atan2(y: float, x: float): float = "auk_fatan2"
pub extern fn exp(x: float): float = "auk_fexp"
/// The natural logarithm.
pub extern fn ln(x: float): float = "auk_fln"
pub extern fn log10(x: float): float = "auk_flog10"
pub extern fn log2(x: float): float = "auk_flog2"
/// The IEEE 754 double-precision bits; `float.from_bits` undoes it.
pub extern fn bits(x: float): int = "auk_fbits"
/// The single-precision bits of `x` rounded to f32 (0 to 2^32 - 1); `float.from_bits32` undoes it.
pub extern fn bits32(x: float): int = "auk_fbits32"

// ---- lists: primitives ----

pub extern fn len<T>(xs: [T]): int = "auk_arr_len"
pub extern fn push<T>(xs: var [T], x: T) = "auk_arr_push"
/// Remove and return the last element.
pub extern fn pop<T>(xs: var [T]): T? = "auk_arr_pop"
/// Insert at index `i` (0 <= i <= len), shifting the rest right.
pub extern fn insert<T>(xs: var [T], i: int, x: T) = "auk_arr_insert +loc"
/// Remove and return element `i`.
pub extern fn remove<T>(xs: var [T], i: int): T = "auk_arr_remove +loc"
/// Element `i`, or none when out of range.
pub extern fn get<T>(xs: [T], i: int): T? = "auk_arr_get_opt"
/// The first `n` elements (fewer if the list is shorter).
pub extern fn take<T>(xs: [T], n: int): [T] = "auk_arr_take"
/// Everything after the first `n` elements.
pub extern fn skip<T>(xs: [T], n: int): [T] = "auk_arr_skip"
/// A reversed copy.
pub extern fn reverse<T>(xs: [T]): [T] = "auk_arr_reversed"
extern fn join_strs(xs: [str], sep: str): str = "auk_arr_join"

// ---- lists: written in Auk ----

pub fn first<T>(xs: [T]): T? = xs.get(0)
pub fn last<T>(xs: [T]): T? = xs.get(xs.len() - 1)

pub fn map<A, B>(xs: [A], f: (A) => B): [B] {
  var out: [B] = []
  for x in xs { out.push(f(x)) }
  out
}

pub fn filter<T>(xs: [T], keep: (T) => bool): [T] {
  var out: [T] = []
  for x in xs {
    if keep(x) { out.push(x) }
  }
  out
}

pub fn reduce<T, A>(xs: [T], init: A, f: (A, T) => A): A {
  var acc = init
  for x in xs { acc = f(acc, x) }
  acc
}

/// The first element that satisfies `pred`.
pub fn find<T>(xs: [T], pred: (T) => bool): T? {
  for x in xs {
    if pred(x) { return x }
  }
  none
}

/// The index of the first element that satisfies `pred`.
pub fn find_index<T>(xs: [T], pred: (T) => bool): int? {
  for i, x in xs {
    if pred(x) { return i }
  }
  none
}

pub fn any<T>(xs: [T], pred: (T) => bool): bool {
  for x in xs {
    if pred(x) { return true }
  }
  false
}

pub fn all<T>(xs: [T], pred: (T) => bool): bool {
  for x in xs {
    if !pred(x) { return false }
  }
  true
}

/// The longest prefix whose elements satisfy `pred`.
pub fn take_while<T>(xs: [T], pred: (T) => bool): [T] {
  var n = 0
  while n < xs.len() && pred(xs[n]) { n += 1 }
  xs.take(n)
}

pub fn contains<T: Eq>(xs: [T], x: T): bool = xs.any(y => y == x)

pub fn sum(xs: [int]): int = xs.reduce(0, (a, b) => a + b)
pub fn sum(xs: [float]): float = xs.reduce(0.0, (a, b) => a + b)

pub fn min<T: Ord>(xs: [T]): T? {
  var best = xs.first()?
  for x in xs {
    if x < best { best = x }
  }
  best
}

pub fn max<T: Ord>(xs: [T]): T? {
  var best = xs.first()?
  for x in xs {
    if x > best { best = x }
  }
  best
}

/// The smaller of two values (`a` when they are equal).
pub fn min<T: Ord>(a: T, b: T): T = if b < a { b } else { a }
/// The larger of two values (`a` when they are equal).
pub fn max<T: Ord>(a: T, b: T): T = if b > a { b } else { a }

/// A sorted copy (stable).
pub extern fn sort<T: Ord>(xs: [T]): [T] = "auk_arr_sorted"

/// A copy sorted by `key` (stable). `key` is called once per element.
pub fn sort_by<T, K: Ord>(xs: [T], key: (T) => K): [T] {
  if xs.len() <= 1 { return xs }
  // sort (key, index) pairs: the index keeps equal keys in their original order
  var ks: [(K, int)] = []
  for i, x in xs { ks.push((key(x), i)) }
  ks.sort().map(p => xs[p.1])
}

/// How many times each distinct element occurs, in first-seen order.
pub fn counts<T: Eq>(xs: [T]): {T: int} {
  var m: {T: int} = {}
  for x in xs { m[x] = (m.get(x) else 0) + 1 }
  m
}

/// Each element with its index: `[(0, a), (1, b)]`.
pub fn enum<T>(xs: [T]): [(int, T)] {
  var out: [(int, T)] = []
  for i, x in xs { out.push((i, x)) }
  out
}

/// Pairs of elements at the same index, as long as the shorter list.
pub fn zip<A, B>(xs: [A], ys: [B]): [(A, B)] {
  let n = if xs.len() < ys.len() { xs.len() } else { ys.len() }
  var out: [(A, B)] = []
  for i in 0..n { out.push((xs[i], ys[i])) }
  out
}

/// The `Show` text of each element, separated by `sep`.
pub fn join<T: Show>(xs: [T], sep: str): str = join_shown(xs, sep)
extern fn join_shown<T>(xs: [T], sep: str): str = "auk_arr_join"

/// Consecutive pieces of `n` elements; the last one may be shorter.
pub fn chunks<T>(xs: [T], n: int): [[T]]
  requires n > 0
{
  var out: [[T]] = []
  var i = 0
  while i < xs.len() {
    out.push(xs[i..min(i + n, xs.len())])
    i += n
  }
  out
}

/// Every run of `n` adjacent elements, in order (none when the list is shorter than `n`).
pub fn windows<T>(xs: [T], n: int): [[T]]
  requires n > 0
{
  var out: [[T]] = []
  var i = 0
  while i + n <= xs.len() {
    out.push(xs[i..i + n])
    i += 1
  }
  out
}

/// `f` of each element, concatenated.
pub fn flat_map<A, B>(xs: [A], f: (A) => [B]): [B] {
  var out: [B] = []
  for x in xs {
    for y in f(x) { out.push(y) }
  }
  out
}

/// The elements grouped by `key`: groups in the order their key first appears, elements in
/// list order.
pub fn group_by<T, K: Eq>(xs: [T], key: (T) => K): {K: [T]} {
  var m: {K: [T]} = {}
  for x in xs {
    let k = key(x)
    if !m.contains(k) { m[k] = [] }
    m[k].push(x)
  }
  m
}

/// The distinct elements, each where it first occurs. O(n): a hash set over `Eq` (the hashing
/// every map key gets).
pub fn unique<T: Eq>(xs: [T]): [T] {
  var seen: {T: bool} = {}
  var out: [T] = []
  for x in xs {
    if !seen.contains(x) {
      seen[x] = true
      out.push(x)
    }
  }
  out
}

// ---- maps ----

pub extern fn len<K, V>(m: {K: V}): int = "auk_map_len"
/// The value for `k`, or none.
pub extern fn get<K, V>(m: {K: V}, k: K): V? = "auk_map_get_opt"
pub extern fn contains<K, V>(m: {K: V}, k: K): bool = "auk_map_contains"
/// Remove `k`, returning its value if it was there.
pub extern fn remove<K, V>(m: var {K: V}, k: K): V? = "auk_map_remove"
/// The keys in insertion order.
pub extern fn keys<K, V>(m: {K: V}): [K] = "auk_map_keys"
pub extern fn values<K, V>(m: {K: V}): [V] = "auk_map_values"
pub fn entries<K, V>(m: {K: V}): [(K, V)] {
  var out: [(K, V)] = []
  for k, v in m { out.push((k, v)) }
  out
}

// ---- sets ----

/// An insertion-ordered set.
pub struct Set<T> { items: {T: bool} }

pub fn set<T>(xs: [T]): Set<T> {
  var m: {T: bool} = {}
  for x in xs { m[x] = true }
  Set { items: m }
}
pub fn len<T>(s: Set<T>): int = s.items.len()
pub fn contains<T>(s: Set<T>, x: T): bool = s.items.contains(x)
pub fn insert<T>(s: var Set<T>, x: T) { s.items[x] = true }
pub fn remove<T>(s: var Set<T>, x: T): bool = s.items.remove(x) is some(_)
pub fn to_list<T>(s: Set<T>): [T] = s.items.keys()
