extern fn nope(): int = "int auk_no_such_c_function(void)"
fn main() uses ffi { print(nope()) }
