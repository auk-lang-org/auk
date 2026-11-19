# Calling C

Auk calls C functions directly. You write the C prototype, and the compiler checks that the
Auk signature fits it and generates the conversion.

## Setup

C can do anything, so calling it is an effect. The package's `raft.toml` must allow `ffi`, and
libraries other than libc are listed under `[link]`:

```toml
[package]
name = "cdemo"
version = "0.1.0"
effects = ["ffi"]

[link]
libs = ["sqlite3"]      # as for the linker's -l; libc needs no entry
```

`[link] macos = [...]` and `linux = [...]` add libraries for one platform only. An entry may
use `${VAR}`, `${VAR:-default}` and `$(tool args)`, for libraries whose location comes from
the environment or a config tool.

## Declaring a C function

```auk
extern fn c_strlen(s: str): int = "size_t strlen(const char *)"
extern fn c_abs(n: int): int = "int abs(int)"
extern fn c_getenv(name: str): str? = "char *getenv(const char *)"
extern fn c_cos(x: float): float = "double cos(double)"

fn main() uses ffi {
  print(c_strlen("hello"))          // 5
  print(c_abs(-7))                  // 7
  print(c_getenv("NOT_SET"))        // none: a NULL result
  print(c_cos(0.0))                 // 1.0
}
```

The string after `=` is the C prototype, exactly as the header gives it. Every call to an
`extern fn` needs `uses ffi`. A signature that doesn't fit its prototype is a compile error
(E0040), not a crash later.

## How types map

| C | Auk |
|---|---|
| integer types (`int`, `size_t`, `int64_t`, ...) | `int` (truncated going in, extended coming out) |
| `bool` | `bool` |
| `float`, `double` | `float` |
| `const char *` | `str` (a result is copied); `str?` when it may be NULL |
| `void` | `()` |
| any other pointer | `ffi.Ptr`, or an `extern type`; `T?` when it may be NULL |
| `T *` pointing at an array | `[T]` (copied in; `var [T]` is copied back out). `[int]` for `void *` is bytes |
| an out-parameter (`int *`, `T **`, `char **`) | a `var` parameter |

For a `char *` result that the caller must free, add the function that frees it:
`"char *make_text(void) +free(free)"`. The text is copied into an Auk string and then freed.

## Opaque pointers

Give each kind of C pointer its own type with `extern type`, so the compiler stops you from
passing a database handle where a statement handle is expected:

```auk
extern type Db = "sqlite3 *"

extern fn sqlite_open(path: str, db: var Db?): int = "int sqlite3_open(const char *, sqlite3 **)"
extern fn sqlite_close(db: Db): int = "int sqlite3_close(sqlite3 *)"
extern fn sqlite_version(): str = "const char *sqlite3_libversion(void)"

fn main(): ()! uses ffi {
  print(sqlite_version())
  var db: Db? = none
  if sqlite_open(":memory:", &db) != 0 { fail("can't open the database") }
  let handle = db else fail("no handle")
  if sqlite_close(handle) != 0 { fail("close failed") }
}
```

The out-parameter `sqlite3 **` is a `var Db?`: it starts as `none` and the call fills it in.
An `extern type` is a plain pointer. It is not reference-counted, so releasing it is your job,
as in C.

A good binding keeps this layer thin and private, and exposes a `pub` API in ordinary Auk
types that returns `T!` instead of status codes.

## Raw memory: the `ffi` module

When a C API hands you a buffer or a struct to read, `ffi` has the pieces:

- `ffi.Ptr`, `ffi.null`, `p.is_null()`, `p.addr()`, `ffi.ptr(n)`, `p.offset(n)`
- `ffi.alloc(n)`, `ffi.free(p)`
- `p.read_u8(offset)`, `read_i32`, `read_i64`, `read_f64`, `read_ptr`, and the matching `p.write_u8(offset, v)`, ...; offsets are in bytes
- `p.cstr()` (a C string as `str`), `ffi.bytes(p, n)`, `ffi.from_bytes(bs)`
- `ffi.symbol(name): ffi.Ptr?` looks a symbol up by name

## Special prototypes

| prototype | meaning |
|---|---|
| `"int64_t (*)(int64_t)"` | call a function by address: the Auk function's first parameter is the address, an `ffi.Ptr` |
| `"(LLVMValueRef)"` | a cast, with no call, between `ffi.Ptr` and an `extern type` |
| `"#embed logo.png"` | the file's contents, read at compile time and stored in the program (the path is relative to the source file). The result type picks the form: `[int]` bytes, `str` text, `ffi.Ptr` address, or `int` length |

`#embed` is the way to ship assets inside a binary:

```auk
extern fn help_text(): str = "#embed help.txt"
```

## Limits

- No variadic C functions (`printf`), no structs passed by value, and no callbacks from C into
  Auk.
- A crash inside C (a segfault, an abort) ends the program. `catch` cannot stop it, and the
  guarantees of the rest of the language end at the `extern` boundary.

`auk run` and `auk test` load the listed libraries dynamically; `auk build` links them.
`packages/llvm` is a large real binding, generated from a list of prototypes.

Back to the [documentation index](../README.md).
