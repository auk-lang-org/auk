struct S { xs: [int] }
fn f(s: S): bool = s?.xs.all(x => x > 0)
