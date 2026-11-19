/// The runtime's low-level dialect (docs/lowlevel.md): raw memory, C layouts, atomics,
/// `setjmp`/`longjmp`. Only the runtime package (`name = "auk_rt"`) can name this module, and
/// everything here `uses raw` but the layout constants (`size_of`, `align_of`, `offset_of`). The
/// intrinsics are compiled inline (`@raw_...`).

/// A memory order for the atomics (C11's `memory_order`, without `consume`).
pub enum Order { Relaxed, Acquire, Release, AcqRel, SeqCst }

/// The buffer of `setjmp`/`longjmp`: C's `jmp_buf` (320 bytes, enough for every supported
/// platform's).
pub raw struct JmpBuf { w: [u64; 40] }

/// The `T` at `p`.
pub extern fn load<T>(p: Ptr<T>): T uses raw = "@raw_load"
/// Write `v` at `p`.
pub extern fn store<T>(p: Ptr<T>, v: T) uses raw = "@raw_store"
/// Element `i` of the array at `p` (also a place: `p.at(i) = v`).
pub extern fn at<T, I>(p: Ptr<T>, i: I): T uses raw = "@raw_at"
/// The address of element `i` (in units of `T`).
pub extern fn offset<T, I>(p: Ptr<T>, i: I): Ptr<T> uses raw = "@raw_offset"
/// The address as an integer (the space keeps `int<` from reading as a unit).
pub extern fn int <T>(p: Ptr<T>): int uses raw = "@raw_ptr_int"
/// Is it NULL?
pub extern fn is_null<P>(p: P): bool uses raw = "@raw_is_null"
/// The address of a raw local or global: `raw.addr_of(&x)`.
pub extern fn addr_of<T>(x: var T): Ptr<T> uses raw = "@raw_addr_of"
/// The address of field `f` of the raw struct at `p`: `raw.field_addr(p, .f)`.
pub extern fn field_addr<T, F>(p: Ptr<T>, f: F): Ptr<F> uses raw = "@raw_field_addr"
/// A pointer (or `ffi.Ptr`, `extern type`, `raw.Fn`) as a pointer to `U`: `raw.cast<U>(p)`.
pub extern fn cast<U, T>(p: T): Ptr<U> uses raw = "@raw_cast"
/// The pointer at address `n`.
pub extern fn from_int<T, I>(n: I): Ptr<T> uses raw = "@raw_from_int"
/// NULL.
pub extern fn null<T>(): Ptr<T> uses raw = "@raw_null"
/// The size of `T` in bytes (a compile-time constant).
pub extern fn size_of<T>(): usize = "@raw_size_of"
/// The alignment of `T` in bytes (a compile-time constant).
pub extern fn align_of<T>(): usize = "@raw_align_of"
/// The offset of field `f` in the raw struct `T`: `raw.offset_of<T>(.f)` (a compile-time constant).
pub extern fn offset_of<T, F>(f: F): usize = "@raw_offset_of"
/// The C address of an `export fn` (or a raw `fn` with C types): a `raw.Fn<F>` (the checker
/// types it).
pub extern fn fn_of<F>(f: F): F uses raw = "@raw_fn_of"

/// Copy `n` bytes (`memcpy`: the areas don't overlap).
pub extern fn copy<T, U, N>(dst: Ptr<T>, src: Ptr<U>, n: N) uses raw = "@raw_copy"
/// Copy `n` bytes that may overlap (`memmove`).
pub extern fn move<T, U, N>(dst: Ptr<T>, src: Ptr<U>, n: N) uses raw = "@raw_move"
/// Set `n` bytes to `b` (`memset`).
pub extern fn fill<T, N>(dst: Ptr<T>, b: u8, n: N) uses raw = "@raw_fill"
/// Compare `n` bytes (`memcmp`): negative, zero or positive.
pub extern fn compare<T, U, N>(a: Ptr<T>, b: Ptr<U>, n: N): i32 uses raw = "@raw_compare"
/// `n` bytes of C memory (`malloc`; aborts when out of memory).
pub extern fn alloc<N>(n: N): Ptr<()> uses raw = "@raw_alloc"
/// Resize C memory (`realloc`; aborts when out of memory).
pub extern fn realloc<T, N>(p: Ptr<T>, n: N): Ptr<()> uses raw = "@raw_realloc"
/// Free C memory (`free`).
pub extern fn free<T>(p: Ptr<T>) uses raw = "@raw_free"

/// Control never gets here (LLVM's `unreachable`).
pub extern fn unreachable(): never uses raw = "@raw_unreachable"
/// Stop the program at once (`llvm.trap`).
pub extern fn trap(): never uses raw = "@raw_trap"
/// `b`, expected to be true (`llvm.expect`).
pub extern fn likely(b: bool): bool uses raw = "@raw_likely"

/// Atomics on integers and pointers; `order` must be a constant (`raw.Order.SeqCst`).
pub extern fn atomic_load<T>(p: Ptr<T>, order: Order): T uses raw = "@raw_atomic_load"
pub extern fn atomic_store<T>(p: Ptr<T>, v: T, order: Order) uses raw = "@raw_atomic_store"
/// Store `v`, return the old value.
pub extern fn atomic_swap<T>(p: Ptr<T>, v: T, order: Order): T uses raw = "@raw_atomic_swap"
/// Compare and swap: the old value, and whether it was `old` (and `new` was stored).
pub extern fn atomic_cas<T>(p: Ptr<T>, old: T, new: T, ok: Order, fail: Order): (T, bool) uses raw = "@raw_atomic_cas"
/// Add, subtract, and, or `v`; return the old value.
pub extern fn atomic_add<T>(p: Ptr<T>, v: T, order: Order): T uses raw = "@raw_atomic_add"
pub extern fn atomic_sub<T>(p: Ptr<T>, v: T, order: Order): T uses raw = "@raw_atomic_sub"
pub extern fn atomic_and<T>(p: Ptr<T>, v: T, order: Order): T uses raw = "@raw_atomic_and"
pub extern fn atomic_or<T>(p: Ptr<T>, v: T, order: Order): T uses raw = "@raw_atomic_or"
/// `a + b` (also `-`, `*`) and whether it overflowed `T` (signed or unsigned by `T`); the
/// first is the wrapped result. On integers.
pub extern fn add_overflow<T>(a: T, b: T): (T, bool) uses raw = "@raw_add_overflow"
pub extern fn sub_overflow<T>(a: T, b: T): (T, bool) uses raw = "@raw_sub_overflow"
pub extern fn mul_overflow<T>(a: T, b: T): (T, bool) uses raw = "@raw_mul_overflow"
/// The trailing (`ctz`) and leading (`clz`) zero bits (the width for 0), the one bits, and the
/// bytes reversed (`bswap`, 16 bits and wider). On integers.
pub extern fn ctz<T>(x: T): T uses raw = "@raw_ctz"
pub extern fn clz<T>(x: T): T uses raw = "@raw_clz"
pub extern fn popcount<T>(x: T): T uses raw = "@raw_popcount"
pub extern fn bswap<T>(x: T): T uses raw = "@raw_bswap"

/// A memory fence.
pub extern fn fence(order: Order) uses raw = "@raw_fence"

/// `_setjmp` (no signal mask, no unwinding): false when called, true when `longjmp` comes
/// back to it. A function that calls it is compiled without optimizations (`optnone`), so its
/// locals hold their last values after the jump back.
pub extern fn setjmp(buf: Ptr<JmpBuf>): bool uses raw = "@raw_setjmp"
/// `_longjmp`: back to the `setjmp` that filled `buf` (its function must not have returned).
pub extern fn longjmp(buf: Ptr<JmpBuf>): never uses raw = "@raw_longjmp"
