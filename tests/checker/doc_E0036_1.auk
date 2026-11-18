extern fn c_abs(n: int): int = "int abs(int)"

fn main() uses ffi { print(c_abs(-3)) }
