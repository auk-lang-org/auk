# Duck vs Rust: runtime performance

Seven programs, written the same way in `duck/` and `rust/` (same algorithm and data structures: `[T]`/`Vec`,
`{K: V}`/`HashMap`, a recursive enum/`Box` tree, a stable sort). The input size comes from argv so neither
compiler can constant-fold. `run.sh` builds Duck with `duck build` (release) and Rust with `-C opt-level=3
-C target-cpu=native`, plus a second Rust build with `overflow-checks=on`, because Duck traps on overflow.
It then times the best of 5 runs and checks that the outputs match.

## Results with the LLVM back end (2026-11-17, Apple Silicon, rustc 1.99.1, best of 3, quiet machine)

| bench | size | rust -O | rust +overflow checks | duck (Cranelift, before) | duck (LLVM) | duck/rust | duck/rust+oc |
|---|---|---|---|---|---|---|---|
| fib (recursion, int math) | 38 | 0.058s | 0.090s | 0.167s | 0.094s | 1.6x | **1.05x** |
| sieve (`[bool]` index/store) | 50M | 0.153s | 0.166s | 1.304s | 0.396s | 2.6x | **2.4x** |
| nbody (`[float]` index/store, float math) | 5M steps | 0.164s | 0.164s | 2.615s | 0.353s | 2.2x | **2.2x** |
| hashmap (`{int: int}` insert/get) | 5M | 0.151s | 0.152s | 0.417s | 0.426s | 2.8x | **2.8x** |
| trees (enum alloc + match) | depth 18 | 1.637s | 1.679s | 3.278s | 2.553s | 1.6x | **1.5x** |
| strings (interp, join, split, chars) | 5M | 0.248s | 0.251s | 0.752s | 0.753s | 3.0x | **3.0x** |
| sort (`xs.sort()` of ints) | 10M | 0.175s | 0.176s | 4.664s | 3.031s | 17x | **17x** |

Items 1 and 2 of the profile below are fixed: the LLVM back end compiles list access, checked arithmetic,
reference counting and the exact float ops inline (`src/mir/llvm/intrin.rs`). What remains:

- **hashmap**: about 38% of the samples are in the runtime's integer hash (`int_hash`), 34% in
  `duck_map_get_opt`. A cheaper integer hash (a multiply-xorshift) is the next step.
- **strings**: about 30% of the samples are in macOS malloc's `free` (it reads the clock), freeing the
  temporary strings interpolation makes (`duck_str_from_int`, then the builder's buffer in
  `duck_sb_finish`). Writing ints straight into the string builder would remove them.
- **sort**: item 3 below still holds.

The absolute times are lower than the table below's mostly because that run was on a heavily loaded machine;
compare within a table.

## Results with Cranelift (2026-11-17, Apple Silicon, rustc 1.99.1, duck at e03bb96 + working tree, loaded machine)

| bench | size | rust -O | rust +overflow checks | duck | duck/rust | duck/rust+oc |
|---|---|---|---|---|---|---|
| fib (recursion, int math) | 38 | 0.177s | 0.415s | 0.893s | **5.0x** | 2.2x |
| sieve (`[bool]` index/store) | 50M | 0.804s | 0.679s | 5.078s | **6.3x** | 7.5x |
| nbody (`[float]` index/store, float math) | 5M steps | 0.636s | 1.360s | 23.03s | **36x** | 17x |
| hashmap (`{int: int}` insert/get) | 5M | 2.045s | 1.808s | 2.980s | **1.5x** | 1.6x |
| trees (enum alloc + match) | depth 18 | 5.691s | 5.614s | 7.030s | **1.2x** | 1.25x |
| strings (interp, join, split, chars) | 5M | 0.389s | 0.382s | 1.166s | **3.0x** | 3.1x |
| sort (`xs.sort()` of ints) | 10M | 0.270s | 0.256s | 11.40s | **42x** | 45x |

## Profile (`sample` on `duck build -g` binaries; IR from `duck ir --clif`, since removed; the LLVM results are above)

1. **Every list read and write is an out-of-line runtime call** (sieve, nbody). `xs[i]` is `duck_arr_at`,
   and `xs[i] = v` is `duck_arr_set`. The set call copies the value into a temporary buffer, retains it
   through the element vtable, calls `ensure_unique_cap` (the copy-on-write check), releases the old
   element and then `memcpy`s the new one. That `memcpy` has a dynamic size, so an 8-byte float store
   becomes a libc call through a dyld stub. In nbody, `duck_arr_set` + `memmove` + `ensure_unique_cap`
   + `duck_arr_at` take about 80% of the samples. Fix (done, in the LLVM back end): inline the fast path for scalar
   element types: a bounds check, a refcount==1 check that branches to the runtime only when the list is
   shared, then a plain load or store.
2. **Checked integer arithmetic is a function call** (fib, sieve). `+ - *` lower to `duck_add`/`duck_sub`
   /`duck_mul(a, b, loc)` instead of an inline `sadd_overflow` + `trapnz`/a cold branch. fib spends about
   27% of its samples in `duck_add`/`duck_sub`. Rust with overflow checks on is still 2.2x faster.
3. **`sort` is a top-down merge sort written in Duck** (`src/prelude/core.duck:296`). `sort` is
   `sort_by(x => x)`. Every level allocates through `take`/`skip`, the merge calls the key closure
   twice per comparison and builds `out` with `push`, and the result is concatenated with `+`. Profile:
   `sort_by` itself, then malloc/free, memmove and `duck_arr_push`/`at`/`len`. Fix: a runtime
   `duck_arr_sort` (Rust's stable `sort_by` on the raw buffer, with an int/float/str fast path and
   the `Ord` cmp otherwise). That alone should bring it to about 1-2x.
4. **Allocation-heavy code is already close** (trees 1.2x, hashmap 1.5x): the RC allocator and map
   are competitive. strings at 3x is mostly per-call overhead in interpolation and `chars()`.

Re-run: `bench/perf/run.sh` (or `bench/perf/run.sh nbody sort`).
