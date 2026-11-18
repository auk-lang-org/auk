extern fn c_abs(n: int): int = "int abs(int)"
fn f(): int = c_abs(-1)
fn main() uses ffi { print(f()) }
