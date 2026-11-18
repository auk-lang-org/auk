// error: E0400 the clauses of `next` don't cover every case: `next(Yellow)` is not handled
enum Light { Red, Yellow, Green }

fn next(Red): Light = Green
fn next(Green): Light = Yellow

fn main() {
  print(next(Red) == Green)
}
