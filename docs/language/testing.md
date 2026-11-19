# Tests, contracts and holes

Auk puts the tools for checking a program in the language itself, next to the code they
check.

## Tests

A `test` block is a named piece of code that must run without failing:

```auk
fn slug(title: str): str = title.lower().split().join("-")

fn parse_pair(s: str): (int, int)! {
  let [a, b] = s.split(",") else fail("expected a,b")
  (int.parse(a.trim())?, int.parse(b.trim())?)
}

test "slug joins words" {
  assert slug("Hello Big World") == "hello-big-world"
  assert slug("") == ""
}

test "parse_pair" {
  let (a, b) = parse_pair("3, 4")?       // tests may use ?: an error fails the test
  assert (a, b) == (3, 4)
  assert parse_pair("3") is err(_)
}
```

```console
$ auk test slug.auk
ok slug joins words
ok parse_pair
2 passed, 0 failed
```

A failing `assert` shows both sides of the comparison:

```console
FAIL bad
    panic: assertion failed: fact(3) == 7
      left: 6
      right: 7
      at b.auk:12:21
1 passed, 1 failed
```

Things to know:

- `auk test file.auk` runs one file's tests. `auk test` in a project (or `auk test dir`) runs
  the project's. A second argument filters by name: `auk test src/main.auk parse`.
- Each test runs in its own process, so a panic or crash fails that test and the rest still
  run. The exit status is 1 if any test failed.
- Tests are left out of `auk build` and `auk run`.
- A test may use any effect without declaring it.
- `auk test --trace=json` prints, under each failure, the last calls the test made, with
  arguments and results. See [Testing and debugging](../tools/debugging.md).

Since values compare with `==` and print themselves, assertions on whole structs and lists
need no helpers: `assert parse(src) == [Num(1.0), Plus, Num(2.0)]`.

## Contracts

`requires` states what a function needs from its caller; `ensures` states what it promises
back. `result` is the return value and `old(e)` is the value `e` had on entry.

```auk
fn isqrt(n: int): int
  requires n >= 0
  ensures result * result <= n
  ensures (result + 1) * (result + 1) > n
{
  var r = 0
  while (r + 1) * (r + 1) <= n { r += 1 }
  r
}

fn withdraw(balance: var int, amount: int)
  requires amount > 0 && amount <= balance
  ensures balance == old(balance) - amount
{
  balance -= amount
}

fn main() {
  print(isqrt(50))     // 7
  var b = 100
  b.withdraw(30)
  print(b)             // 70
}
```

- `requires` is checked in every build, including release. A violation is a panic that quotes
  the contract: `panic: requires failed: n >= 0`.
- `ensures` is checked by `auk run` and `auk test`, and compiled out of `auk build`.
- Contracts must be pure.

A contract is documentation the compiler keeps true, and it turns every test and every run
into a check of that function. Contracts are also the most precise way to tell someone else,
or a model, what a function is supposed to do before it exists.

## Holes

`??` is a hole: a placeholder for code that isn't written yet. A program with holes
type-checks, runs and can be tested; reaching a hole at run time is a panic. `auk build`
refuses a program that still has one.

```auk
fn isqrt(n: int): int
  requires n >= 0
  ensures result * result <= n
{ ?? }

test "isqrt" { assert isqrt(17) == 4 }
```

This lets you write signatures, contracts and tests first and fill in bodies afterwards.
`auk holes` reports what each hole needs:

```console
$ auk holes isqrt.auk
hole 1 at isqrt.auk:4:3 in fn isqrt
  expected type: int
  the hole is a whole block body: `{ ?? }` (replace it with the block's statements)
  function:
    fn isqrt(n: int): int
      requires n >= 0
      ensures result * result <= n
  in scope:
    n: int
  tests that call it:
    test "isqrt" { assert isqrt(17) == 4 }
```

That brief is everything needed to write the body, which makes holes a clean way to hand a
well-specified piece of work to a colleague or to an AI model. `auk holes --json` gives the
same as data, and [`auk hatch`](../tools/ai.md#filling-holes-auk-hatch) fills holes with a
model and keeps an answer only if it type-checks and passes the tests.

(`??` is only a hole. The "default if missing" operator is `else`.)

## `peek`

`peek e` prints the expression and its value to stderr, with the location, and returns the
value, so it can be dropped into the middle of any expression:

```auk
fn main() {
  let xs = [3, 1, 2]
  let top = peek xs.sort().last()     // [main.auk:3] xs.sort().last() = some(3)
  print(top)
}
```

To inspect values without editing the code at all, use
[`auk debug`](../tools/debugging.md#auk-debug).

## `imprint`: compute at compile time

An `imprint` is a constant whose value is computed while compiling and stored in the program.
Its initializer may call any pure function:

```auk
fn is_prime(n: int): bool = n > 1 && (2..n).all(d => n % d != 0)

imprint PRIMES = (0..50).filter(n => is_prime(n))

fn main() {
  print(PRIMES.len())   // 15: nothing is computed at run time
}
```

Use it for lookup tables and parsed constants. A panic while computing one is a compile error
(E0420) pointing at the imprint.

Next: [Modules and packages](modules.md).
