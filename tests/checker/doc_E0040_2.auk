extern fn strlen(s: str): int = "size_t strlen(const char *)"

fn main() uses ffi { print(strlen("hello")) }
