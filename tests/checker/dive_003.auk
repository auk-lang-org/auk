6765 : int
40 : int
dive:1:4: error[E0400]: the clauses of `g` don't cover every case: `g(_)` is not handled
  |
1 | fn g(0): int = 0
  |    ^
  = note: add a clause for each missing case
  = fix: insert `
fn g(_): int = ??` at 1:17
  = help: run `auk explain E0400` for details
2 : int
<fn> : (int) => int
[1, 2, 3] : [int]
6 : int
