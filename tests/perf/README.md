# Auk vs Rust: runtime performance

Seven programs, written the same way in `auk/` and `rust/` (same algorithm and data structures: `[T]`/`Vec`,
`{K: V}`/`HashMap`, a recursive enum/`Box` tree, a stable sort). The input size comes from argv so neither
compiler can constant-fold. `run.sh` builds Auk with `auk build` (release) and Rust with `-C opt-level=3
-C target-cpu=native`, plus a second Rust build with `overflow-checks=on`, because Auk traps on overflow.
It then times the best of 5 runs and checks that the outputs match.

## Results (2026-11-17, Apple Silicon, rustc 1.99.1, `auk build` with the LLVM back end, best of 5, quiet machine)

| bench | size | rust -O | rust +overflow checks | auk (Cranelift, before the port) | auk | auk/rust | auk/rust+oc |
|---|---|---|---|---|---|---|---|
| fib (recursion, int math) | 38 | 0.058s | 0.086s | 0.157s | 0.092s | 1.6x | **1.07x** |
| sieve (`[bool]` index/store) | 50M | 0.166s | 0.168s | 1.278s | 0.399s | 2.4x | **2.4x** |
| nbody (`[float]` index/store, float math) | 5M steps | 0.162s | 0.162s | 2.576s | 0.350s | 2.2x | **2.2x** |
| hashmap (`{int: int}` insert/get) | 5M | 0.160s | 0.158s | 0.449s | 0.266s | 1.7x | **1.7x** |
| trees (enum alloc + match) | depth 18 | 1.617s | 1.648s | 3.276s | 2.594s | 1.6x | **1.6x** |
| strings (interp, join, split, chars) | 5M | 0.246s | 0.251s | 0.771s | 0.451s | 1.8x | **1.8x** |
| sort (`xs.sort()` of ints) | 10M | 0.178s | 0.190s | 4.681s | 0.163s | 0.92x | **0.86x** |

What changed since the Cranelift profile below:

- Items 1 and 2 are fixed: the back end compiles list access, checked arithmetic, reference
  counting and the exact float ops inline (`src/mir/llvm/intrin.rs`).
- Item 3 is fixed: `sort` is the runtime's (`auk_arr_sorted`: ints and floats sorted as values,
  anything else through a permutation by the element ops' `cmp`).
- Maps: index slots carry a hash fingerprint and keys sit with their values (about two cache misses
  per lookup instead of four), and `m[k] = (m.get(k) else d) op x` is one lookup when `k` is present.
- Strings: the string builder keeps short text inline and interpolating an int writes its digits
  straight into it, so `"w{i}"` allocates only the result.

What remains: allocation (strings: every `split` piece and map key is a heap string, and macOS `free`
reads the clock; trees: a box per node), the cache misses of a big map, and list writes' copy-on-write
checks.

The Cranelift table below was measured on a heavily loaded machine; compare within a table.

## Results with Cranelift, before the port (2026-11-17, auk at e03bb96, loaded machine)

| bench | size | rust -O | rust +overflow checks | auk | auk/rust | auk/rust+oc |
|---|---|---|---|---|---|---|
| fib (recursion, int math) | 38 | 0.177s | 0.415s | 0.893s | **5.0x** | 2.2x |
| sieve (`[bool]` index/store) | 50M | 0.804s | 0.679s | 5.078s | **6.3x** | 7.5x |
| nbody (`[float]` index/store, float math) | 5M steps | 0.636s | 1.360s | 23.03s | **36x** | 17x |
| hashmap (`{int: int}` insert/get) | 5M | 2.045s | 1.808s | 2.980s | **1.5x** | 1.6x |
| trees (enum alloc + match) | depth 18 | 5.691s | 5.614s | 7.030s | **1.2x** | 1.25x |
| strings (interp, join, split, chars) | 5M | 0.389s | 0.382s | 1.166s | **3.0x** | 3.1x |
| sort (`xs.sort()` of ints) | 10M | 0.270s | 0.256s | 11.40s | **42x** | 45x |

## Profile (`sample` on `auk build -g` binaries; IR from `auk ir --clif`, since removed; the LLVM results are above)

1. **Every list read and write is an out-of-line runtime call** (sieve, nbody). `xs[i]` is `auk_arr_at`,
   and `xs[i] = v` is `auk_arr_set`. The set call copies the value into a temporary buffer, retains it
   through the element vtable, calls `ensure_unique_cap` (the copy-on-write check), releases the old
   element and then `memcpy`s the new one. That `memcpy` has a dynamic size, so an 8-byte float store
   becomes a libc call through a dyld stub. In nbody, `auk_arr_set` + `memmove` + `ensure_unique_cap`
   + `auk_arr_at` take about 80% of the samples. Fix (done, in the LLVM back end): inline the fast path for scalar
   element types: a bounds check, a refcount==1 check that branches to the runtime only when the list is
   shared, then a plain load or store.
2. **Checked integer arithmetic is a function call** (fib, sieve). `+ - *` lower to `auk_add`/`auk_sub`
   /`auk_mul(a, b, loc)` instead of an inline `sadd_overflow` + `trapnz`/a cold branch. fib spends about
   27% of its samples in `auk_add`/`auk_sub`. Rust with overflow checks on is still 2.2x faster.
3. **`sort` is a top-down merge sort written in Auk** (`compiler/prelude/core.auk:296`). `sort` is
   `sort_by(x => x)`. Every level allocates through `take`/`skip`, the merge calls the key closure
   twice per comparison and builds `out` with `push`, and the result is concatenated with `+`. Profile:
   `sort_by` itself, then malloc/free, memmove and `auk_arr_push`/`at`/`len`. Fix: a runtime
   `auk_arr_sort` (Rust's stable `sort_by` on the raw buffer, with an int/float/str fast path and
   the `Ord` cmp otherwise). That alone should bring it to about 1-2x.
4. **Allocation-heavy code is already close** (trees 1.2x, hashmap 1.5x): the RC allocator and map
   are competitive. strings at 3x is mostly per-call overhead in interpolation and `chars()`.

Re-run: `tests/perf/run.sh` (or `tests/perf/run.sh nbody sort`).
