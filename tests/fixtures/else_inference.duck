// `else` and `!` in tail position: the expected type flows through as the value type (a
// `T!`/`T?` return expects a plain `T`), never binding a generic call's `T` to `int!`.

// `T!` tail
fn top(ns: [int]): int! { ns.max() else fail("no ages") }
fn low(ns: [int]): int! { ns.min() else fail("empty") }
fn big(ns: [int]): int! { ns.find(n => n > 10) else fail("none big") }
fn head(ws: [str]): str! { ws.first() else fail("no words") }
fn at(ns: [int], i: int): int! { ns.get(i) else fail("no index {i}") }
fn lookup(m: {str: int}, k: str): int! { m.get(k) else fail("no key {k}") }
fn nth<T>(xs: [T], i: int): T! = if i < xs.len() { xs[i] } else { fail("short") }
fn nth_or(ns: [int], i: int): int! { nth(ns, i) else e => fail("nth: {e}") }

// `T?` tail
fn top_o(ns: [int]): int? { ns.max() else -1 }
fn low_o(ns: [int]): int? { ns.min() else return none }
fn big_o(ns: [int]): int? { ns.find(n => n > 10) else 0 }
fn head_o(ws: [str]): str? { ws.first() else "" }
fn at_o(m: {str: int?}, k: str): int? { m.get(k) else none }
fn first_o(xs: [int?]): int? { xs.first() else none }

// `!` in tail position
fn top_u(ns: [int]): int! { ns.max()! }
fn top_uo(ns: [int]): int? { ns.max()! }

// plain tail
fn top_p(ns: [int]): int { ns.max() else 0 }
fn low_p(ns: [int]): int { ns.min() else 0 }
fn big_p(ns: [int]): int { ns.find(n => n > 10) else 0 }
fn head_p(ws: [str]): str { ws.first() else "-" }
fn at_p(m: {str: int}, k: str): int { m.get(k) else 0 }

fn nth_p(ns: [int], i: int): int {
  nth(ns, i) else e => {
    print("{e}")
    0
  }
}

fn main() {
  print("{top([3, 9, 2]) else 0} {low([3, 9, 2]) else 0} {big([3, 19]) else 0} {head(["a"]) else ""}")
  print("{at([5], 0) else 0} {lookup({"a": 1}, "a") else 0} {nth_or([4], 0) else 0}")
  print(top([]) is err(_))
  print(
    match nth_or([], 1) {
      ok(v) => "{v}"
      err(e) => "{e}"
    },
  )
  print("{top_o([]) else 7} {low_o([]) else 7} {big_o([1]) else 7} {head_o([]) else "x"} {at_o({"a": none}, "a") else 7} {first_o([]) else 7}")
  print("{top_u([4, 8]) else 0} {top_uo([4, 8]) else 0}")
  print("{top_p([1, 2])} {low_p([1, 2])} {big_p([])} {head_p([])} {at_p({"a": 3}, "b")} {nth_p([], 0)}")
}
