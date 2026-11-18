/// Micro-benchmarks for the performance cliffs in docs/pilot-report.md (in-place mutation,
/// moving out of a container, string building, `match` on `str`, slicing). Build with `auk build` and run with
/// an iteration count: `auk build compiler/bench/cliffs.auk -o /tmp/cliffs && /tmp/cliffs 80000`.

struct Holder { xs: [int], n: int }

fn push_via_var(h: var Holder, x: int) { h.xs.push(x) }

fn bench(name: str, t0: int) uses time { print("{name}: {time.now() - t0} ms") }

fn keyword(s: str): int = match s {
  "fn" => 1
  "let" => 2
  "var" => 3
  "if" => 4
  "else" => 5
  "match" => 6
  "loop" => 7
  "while" => 8
  "for" => 9
  "in" => 10
  "return" => 11
  "break" => 12
  "continue" => 13
  "struct" => 14
  "enum" => 15
  "shape" => 16
  "pub" => 17
  "use" => 18
  "test" => 19
  "true" => 20
  _ => 0
}

fn main(args: [str]) uses time {
  let n = int.parse(args.get(1) else "100000") else 100000

  // 1. push through a var parameter into a struct field
  var t = time.now()
  var h = Holder { xs: [], n: 0 }
  for i in 0..n { push_via_var(&h, i) }
  bench("struct field push via var param ({h.xs.len()})", t)

  // 2. push into a list element of a list
  t = time.now()
  var ls: [[int]] = [[]]
  for i in 0..n { ls[0].push(i) }
  bench("xs[0].push ({ls[0].len()})", t)

  // 3. push into a map value
  t = time.now()
  var m: {str: [int]} = {"k": []}
  for i in 0..n { m["k"].push(i) }
  bench("m[k].push ({m["k"].len()})", t)

  // 4. take an element out, push, put it back
  t = time.now()
  var ls2: [[int]] = [[]]
  for i in 0..n {
    var x = ls2[0]
    x.push(i)
    ls2[0] = x
  }
  bench("x = xs[0]; x.push; xs[0] = x ({ls2[0].len()})", t)

  // 5. string += in a loop
  t = time.now()
  var s = ""
  for i in 0..n { s += "x" }
  bench("s += \"x\" ({s.len()})", t)

  // 6. [str] + join
  t = time.now()
  var parts: [str] = []
  for i in 0..n { parts.push("x") }
  let j = parts.join("")
  bench("parts.push + join ({j.len()})", t)

  // 7. str of chars: one big, and many short slices (identifiers in a lexer)
  var cs: [char] = []
  for i in 0..n { cs.push('x') }
  t = time.now()
  let s2 = str(cs)
  bench("str([char]) ({s2.len()})", t)
  t = time.now()
  var idents = 0
  for i in 0..n * 10 { idents += str(cs[0..8]).len() }
  bench("str(cs[0..8]) x {n * 10} ({idents})", t)

  // 8. match on str: 20 keyword arms
  t = time.now()
  let words = ["while", "x", "continue", "fn", "parse_expr", "true", "shape", "a"]
  var hits = 0
  for i in 0..n * 10 { hits += keyword(words[i % 8]) }
  bench("match on str, 20 arms, {n * 10} lookups ({hits})", t)

  // 9. slicing a non-ASCII string by char index
  t = time.now()
  let text = "é" + "a".repeat(n)
  var total = 0
  for i in 0..1000 { total += text[i..i + 5].len() }
  bench("1000 slices of a non-ASCII str of {n} chars ({total})", t)
  t = time.now()
  let ascii = "a".repeat(n)
  total = 0
  for i in 0..1000 { total += ascii[i..i + 5].len() }
  bench("1000 slices of an ASCII str of {n} chars ({total})", t)
}
