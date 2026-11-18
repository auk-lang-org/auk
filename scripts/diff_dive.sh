#!/usr/bin/env bash
# Diff `auk dive` (Rust, src/repl.rs) and its Auk port (`compiler dive`, compiler/src/dive.auk;
# see docs/self-host-plan.md, Phase 5): feed the same scripted stdin sessions to each, in the
# same scratch directory one after the other, and compare every session's stdout, stderr and
# exit code, and the files it leaves (`:save`). The session's temporary directory
# ($TMPDIR/auk-dive-<pid>) is normalized to `auk-dive-PID`.
#
# Usage: scripts/diff_dive.sh [<port binary>]   (default: build target/pilot/compiler)
source "$(dirname "$0")/pilot_common.sh"
if [ -n "${1:-}" ]; then
  PORT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  cargo build --release -q
else
  build_both
fi
OUT="$ROOT/target/pilot/dive-diff"
rm -rf "$OUT"
mkdir -p "$OUT/in"
W="$OUT/work" # the sessions' directory, the same path for both binaries

# session NAME [ARGS...] < input: a session's input (stdin) and `dive` arguments (default
# --quiet; `-` for none).
names=()
session() {
  local name="$1"
  shift
  cat > "$OUT/in/$name"
  printf '%s\n' "${@:---quiet}" > "$OUT/in/$name.args"
  names+=("$name")
}

session values << 'EOF'
1 + 2 * 3
let xs = [1, 2, 3]
xs.map(x => x * 2)
fn sum_to(n: int): int {
  var t = 0
  for i in 1..=n {
    t += i
  }
  t
}
sum_to(10)
struct Point { x: float, y: float }
enum Shape { Circle(r: float), Rect(w: float, h: float) }
fn area(Circle(r)): float = 3.0 * r * r
fn area(Rect(w, h)): float = w * h
area(Rect(2.0, 3.5))
print("hello from a statement")
let p = Point { x: 1.0, y: 2.0 }
p
"hi"
"quote \" and \\ and \u{1F986}"
'c'
true && false
1.5 / 4.0
[[1], [], [2, 3]]
{"a": 1, "b": 2}
(1, "two", 3.0)
some(3)
xs.get(10)
int.parse("12")
int.parse("x")
xs.len() + "a"
xs.len()
let big = 9223372036854775807
let boom = big + 1
big
:type xs.map(x => "{x}")
:items
:save session.auk
:reset
xs
:quit
1 + 1
EOF

session clauses << 'EOF'
fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)
fib(20)
fn fib(n: int): int = n * 2
fib(20)
fn g(0): int = 0
1 + 1
let inc = (x: int) => x + 1
inc
var ys = [1]
ys.push(2)
ys.push(inc(2))
ys
let total =
  ys.sum()
total
fn h(0): int = 10
fn h(n: int): int = n + 1
h(0) + h(5)
fn k(0): int = 0

fn k(1): int = 1
/// docs
fn k(n: int): int = n
k(7)
:items
fn m(true): str = "yes"
fn m(false): str = "no"
m(1 < 2)
fn q(0): int = 0
EOF

session load << 'EOF'
:load lib.auk
double(21)
fn bad(x: int): int {
  let y = x + 1
  y + "s"
}
:items
let s = [1,
  2,

:load broken.auk
:load syntax.auk
:load missing.auk
:load .
:load clash.auk
double(1)
:help
EOF

session commands << 'EOF'
:h
:?
:t
:t 1 + 1
:type
:type "a" + 1
:type [1, 2].map(x => x > 1)
:items
:reset
:load
:save
:explain E0002
:explain e0400
:explain E9999
:explain E0001 E0002
:explain
:nope
:nope with args
  :items
:items extra
:exit
1
EOF

session quit_q << 'EOF'
1 + 1
:q
2 + 2
EOF

session statements << 'EOF'
var n = 0
n += 1
n = n * 10
n
for i in 0..3 {
  print("i = {i}")
}
while n > 5 {
  n -= 3
}
n
assert n == 4
assert n == 5
n
let (a, b) = (1, 2)
a + b
let s = "x"
s.len()
xs
let xs = [3, 1, 2]
xs.sort()
var m: {str: int} = {}
m["k"] = 7
m
EOF

session panics << 'EOF'
let xs = [1, 2]
print("before")
xs[5]
xs[1]
print("again")
panic("boom")
let r: int! = fail("bad")
fn f(x: int): int! {
  if x > 2 { fail("too big") }
  x
}
f(1)
f(5)
let v = f(9)?
1 / 0
fn loop_down(n: int): int = if n == 0 { 0 } else { 1 + loop_down(n - 1) }
loop_down(10)
fn needs(x: int): int
  requires x > 0
{ x }
needs(0)
needs(2)
EOF

session multiline << 'EOF'
1 +
  2 +
  3
[1,
 2,
 3]
let t = """
  first

  third
  """
t
/* a block
comment */ 5
let longer = [
  1,

fn f(x: int): int {
  x +

  1
}
f(2)
(1, 2,
EOF

session syntax << 'EOF'
1 +* 2
)
let = 5
fn (x) = 1
struct { }
fn main() { print(1) }
struct A { x: int } struct B { y: int }
"unterminated
1 + 1
let x = 1; let y = 2
EOF

session items << 'EOF'
struct P { x: int }
P { x: 1 }
struct P { x: int, y: int }
P { x: 1, y: 2 }
P { x: 1 }
enum Color { Red, Green }
Color.Red
shape Named {
  fn name(self): str
}
fn name(p: P): str = "P{p.x}"
P { x: 3, y: 4 }.name()
test "t" { assert 1 == 1 }
test "t" { assert 2 == 2 }
imprint SQUARES = [1, 4, 9]
SQUARES
imprint SQUARES = [0]
SQUARES
pub fn pubfn(): int = 3
pubfn()
async fn later(): int = 5
later()
await later()
fn bad(): int = "s"
fn uses_missing(): int = nothing()
fn twice(x: int): int = x * 2
fn twice(x: int, y: int): int = x * y
twice(2) + twice(2, 3)
/// A documented thing.
/// Two lines.
fn doc(): int = 1
fn header(n: int): int
  requires n >= 0
fn header(0): int = 0
fn header(n: int): int = n
header(3)
:items
:save saved.auk
EOF

session unit_and_never << 'EOF'
var xs = [1]
xs.push(2)
xs
()
print("shown once")
xs
if xs.len() > 1 { print("big") } else { print("small") }
let f = (x: int) => x * 2
f
[f]
f(4)
let task = async { 1 + 1 }
await task
EOF

session more << 'EOF'
fail("never")
print("out")
{
  print("inside")
  41 + 1
}
let s = "a"
s + "b"
:save /nonexistent-dir/x.auk
:load only_main.auk
:items
:type fail("x")
:type
:type )
EOF

session effects << 'EOF'
fs.write("file.txt", "content")?
fs.read("file.txt")
env.read_line()
let h = env.get("AUK_DIVE_DIFF")
h
:save effects.auk
EOF

session eof_pending << 'EOF'
fn p(0): int = 0
EOF

session eof_buffer << 'EOF'
let x = [1,
  2
EOF

session eof_noline < <(printf '1 + 1\nfn p(0): int = 0')
session crlf < <(printf '1 + 1\r\nlet x = 2\r\nx * 3\r\n')
session empty < /dev/null
session blank < <(printf '\n\n   \n')
session quiet_short -q << 'EOF'
2 * 21
EOF
session bad_flag --nope << 'EOF'
1
EOF
session extra_arg --quiet extra << 'EOF'
1
EOF
session no_flags - << 'EOF'
3 + 4
EOF

files() {
  mkdir -p "$W"
  printf 'fn double(x: int): int = x * 2\n\nfn main() {\n  print(double(2))\n}\n' > "$W/lib.auk"
  printf 'fn ok(): int = 1\n\nfn broken(): int {\n  "no"\n}\n' > "$W/broken.auk"
  printf 'fn ok(: int = 1\n' > "$W/syntax.auk"
  printf 'fn double(x: int): int = x + x\n' > "$W/clash.auk"
  printf 'fn main() {\n  print(1)\n}\n' > "$W/only_main.auk"
}

for side in rust auk; do
  BIN="$AUK"
  [ "$side" = auk ] && BIN="$PORT"
  LOG="$OUT/$side.log"
  : > "$LOG"
  rm -rf "$W"
  files
  for name in "${names[@]}"; do
    args=()
    while IFS= read -r a; do [ "$a" = - ] || args+=("$a"); done < "$OUT/in/$name.args"
    rc=0
    (cd "$W" && AUK_DIVE_DIFF=set "$BIN" dive ${args[@]+"${args[@]}"} < "$OUT/in/$name") > "$OUT/stdout" 2> "$OUT/stderr" || rc=$?
    {
      echo "== $name: dive ${args[*]-}"
      sed -E -e 's/auk-dive-[0-9]+/auk-dive-PID/g' -e "s|$W|<dir>|g" "$OUT/stdout"
      echo "-- stderr"
      sed -E -e 's/auk-dive-[0-9]+/auk-dive-PID/g' -e "s|$W|<dir>|g" "$OUT/stderr"
      echo "-- exit $rc"
    } >> "$LOG"
  done
  # on a terminal (`script` gives the session one): the banner and the prompts, `..` for a
  # continued input, Ctrl-D at the end
  if [ "$(uname)" = Darwin ]; then tty_cmd=(script -q /dev/null "$BIN" dive); else tty_cmd=(script -qec "$BIN dive" /dev/null); fi
  rc=0
  (cd "$W" && (sleep 1; printf '1 + 1\nlet x = [1,\n2]\nfn g(0): int = 0\nfn g(n: int): int = n\ng(4) + x.len()\n'; sleep 3) | "${tty_cmd[@]}") > "$OUT/stdout" 2>&1 || rc=$?
  {
    echo "== tty: dive"
    tr -d '\r' < "$OUT/stdout" | sed -e 's/^^D[[:cntrl:]]*//'
    echo "-- exit $rc"
  } >> "$LOG"
  # what the sessions saved
  for f in "$W"/*; do
    echo "== file $(basename "$f")" >> "$LOG"
    cat "$f" >> "$LOG"
  done
  # no session directory is left behind
  if ls -d "${TMPDIR:-/tmp}"/auk-dive-* > /dev/null 2>&1; then
    echo "== leftover session directories" >> "$LOG"
  fi
done
n=${#names[@]}
if cmp -s "$OUT/rust.log" "$OUT/auk.log"; then
  echo "dive: $n sessions (and one on a terminal), 0 differ"
else
  diff "$OUT/rust.log" "$OUT/auk.log" | head -60 || true
  echo "dive: $n sessions; outputs differ (diff $OUT/rust.log $OUT/auk.log)"
  exit 1
fi
