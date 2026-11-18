extern fn strlen(s: str): str = "size_t strlen(const char *)"

fn main() uses ffi { print(strlen("hello")) }
