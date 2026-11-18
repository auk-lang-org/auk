# Self-hosting pilot: the front end in Auk

Phase 2e of [self-host-plan.md](self-host-plan.md): port the lexer and parser from Rust to Auk,
check that both produce byte-identical output on the corpus, time them, and decide go/no-go.
Every gap the port ran into is listed below with the snippet that shows it (the input to 2d).

## What was ported

| Rust (non-test lines) | Auk (`compiler/src/`) |
|---|---|
| `token.rs` (268) | `token.auk` (398: the `match` tables are one arm per line) |
| `lexer.rs` (756) | `lexer.auk` (951) |
| `ast.rs` (794, half of it the old S-expression dump) | `ast.auk` (306) |
| `parser.rs` (1610) | `parser.auk` (2073) |
| `units.rs`, the `parse` half (~80) | `units.auk` (79) |
| `diag.rs`, `Span`/`Diag`/`Fix` (~60) | `diag.auk` (39) |
| `dump.rs` (new, 773 with tests) | `dump.auk` (650), `main.auk` (52) |

`compiler/` is an ordinary Auk project (`raft.toml`, effects `fs env time`). Everything is a
straight port: same functions, same order of node ids, same diagnostics (codes, spans, messages,
notes, fix-its). Where Auk forced a different shape the comments say so (see the gaps below).

**Oracles.** `auk dump tokens|ast [--quiet] [--time] [--repeat N] <file>...` (hidden; `src/dump.rs`)
prints the token stream (kind, payload, span, `space`, doc) with interpolation tokens nested, or
the AST with every node's span and NodeId, one node per line. Strings are escaped by one simple
rule, floats print as their IEEE bits and chars as code points, so the format is easy to
reproduce exactly. Unit tests: `dump::tests::{token_dump, ast_dump}`.

**Diff scripts.** `scripts/diff_tokens.sh` and `scripts/diff_ast.sh` build both (`cargo build
--release`, `auk build compiler/src/main.auk`) and dump every `.auk` under `tests/ examples/
packages/ src/prelude/ compiler/src/ compiler/tests/`. A file under a `prelude/` directory is
parsed as a prelude file (`extern` allowed). `compiler/tests/lex/` (41 files) and
`compiler/tests/parse/` (70 files) add error cases taken from the Rust unit tests (every lexer
and parser diagnostic code: E0001–E0013, E0020–E0039), per-item error recovery, prelude-only forms, and one file
that uses every construct.

## Results

```
tokens: 221 files, 0 differ
ast: 221 files, 0 differ
```

Both were at zero on the first full run; lexer errors and parse errors (codes, spans, messages,
notes, fix-its, several errors per file) included.

## Timing

`scripts/pilot_time.sh` on the golden corpus (102 files, 862 KB), Apple M5, release builds
(Rust: `cargo build --release`; Auk: `auk build`, i.e. LLVM O2 with the runtime's bitcode
inlined). In-process time excludes reading the files and is per pass over the whole corpus (each
run does 20 passes); the best run counts. Whole-process time writes the full dump to `/dev/null`.

| measure | Rust | Auk | Auk / Rust |
|---|---|---|---|
| lex, in-process | 10.4 ms | 28.2 ms | **2.70x** |
| lex + parse, in-process | 27.1 ms | 54.7 ms | **2.02x** |
| parse alone (difference) | 16.7 ms | 26.5 ms | **1.59x** |
| lex + token dump, whole process | 73 ms | 86 ms | 1.18x |
| lex + parse + AST dump, whole process | 86 ms | 111 ms | 1.29x |

(Best of 5. A second run, best of 7 with Rust and Auk alternating, on a machine busy with another
agent's ASan suite: lex 2.62x, lex + parse 2.10x, parse alone 1.80x, dumps 1.20x / 1.36x.)

### After 2d (performance)

The same script after the 2d codegen/runtime work (borrowed element reads, no RC for field-less
variants, moving pushes, `match` on `str` by table, `str` of chars in one buffer, in-place
`s +=`, moving an element out and back), on the grown corpus (119 files, 955 KB), best of 7,
Rust and Auk alternating, on a loaded machine (load average ~20); "before" is main at 8b3c21a
measured in the same session:

| measure | Rust | Auk before | Auk after 2d | Auk / Rust before | after |
|---|---|---|---|---|---|
| lex, in-process | 19.1 ms | 56.3 ms | 37.2 ms | 2.98x | **1.94x** |
| lex + parse, in-process | 53.2 ms | 111.9 ms | 84.8 ms | 2.09x | **1.59x** |
| parse alone (difference) | 34.1 ms | 55.6 ms | 47.6 ms | 1.63x | **1.40x** |
| lex + token dump, whole process | 125 ms | 151 ms | 136 ms | 1.09x | 1.09x |
| lex + parse + AST dump, whole process | 151 ms | 209 ms | 174 ms | 1.39x | 1.15x |

Port against port (the same binaries alternating, best of 9): lexing 50.1 → 35.7 ms (-29%),
lexing + parsing 108.0 → 80.9 ms (-25%). By step, on the port (each against the previous step):
reads without RC and moving pushes -9% lexing / -15% parsing; `match` on `str` -4% lexing; `str`
of chars (and of a char range without the slice) with in-place `+=` -22% lexing (noisy: the
machine was loaded).

`compiler/bench/cliffs.auk` (80k iterations; best of 3, before → after):

| case | before | after |
|---|---|---|
| `var x = xs[0]; x.push(i); xs[0] = x` | 869 ms | 1–2 ms |
| `s += "x"` | 191 ms | 1–2 ms |
| `parts.push("x")` + `join` (reference) | 2 ms | 1–2 ms |
| `str(cs[0..8])`, 800k times | 86 ms | 22 ms |
| `match` on `str`, 20 arms, 800k lookups | 24 ms | 7 ms |

Not done: one allocation per AST node. Boxing only the enum's recursive fields (keeping
`ExprKind` inline in `Expr`) made a binary-tree benchmark 2.5x faster but the Auk parser 9–11%
slower, because every `Expr` copy then carries the whole `ExprKind`; the right shape is one box
for a variant's whole payload, a bigger change left for later.

The whole-process numbers are dominated by writing the dump, where the Auk version (`[str]`
lines joined once) is slightly faster than the Rust one (`format!` per line); they are shown
only to say that start-up and output don't change the picture.

## Profile

`sample` on the Auk binary (`--repeat 300`, lexing only, and `--repeat 150`, lexing + parsing),
summarized per function (inclusive / self):

**Lexing** (`tokens`):

| | incl. | self |
|---|---|---|
| `next_token` (with `token`, `skip_trivia` inlined) | 69% | 13% |
| `string` (string literals: `[(char, bool)]` pieces, `map`, `str(chars)`) | 19% | 1.5% |
| `auk_arr_push` (incl. growth: `realloc`, `memmove`) | 19% | 4% |
| `auk_str_from_chars` (identifiers and literal text: `str(chars[a..b])`) | 13% | 0.6% |
| `Tok` retain + release (`dk_rc320_*`) | 13% | 13% |
| `insert_newlines` | 12% | 3.5% |
| `keyword` (a `match` on `str`: a chain of `auk_str_eq`) | 10% | 1.5% |
| malloc + free (all callers) | ~20% | |

**Lexing + parsing** (`ast`): lexing is 43%, items 41%, freeing memory (`auk__free_now`) 13%.

| | incl. | self |
|---|---|---|
| `Tok` retain + release (`dk_rc320_*`) | 18% | 18% |
| `peek` / `at` (copy the current `Tok` out of the token list, compare, release) | 10% / 10% | 4% / 2% |
| malloc + free (nodes, boxes, lists) | ~20% | |
| `DkBox30_drop` (freeing boxed `ExprKind`s) | 5.5% | |
| `auk_str_eq` | 5% | 4% |

**Where the time goes, and the path to closer.** The parser's own logic is a small part: most
of the gap is reference counting and allocation that Rust doesn't do.

1. *Reads retain.* `p.peek()` returns an owned `Tok`, so every look at the current token is an
   atomic retain plus a release; `p.toks[p.pos].tok == t` is worse: it copies and retains the
   whole `Token` (including its doc string) to read one field:
   ```c
   v4 = *(DkS26_Token *)auk_arr_at(v2.f0, v2.f2, ...);
   dk_rc319_retain(v4);
   v6 = dk_eq321(v5.f0, v3);
   dk_rc319_release(v5);
   ```
   Comparing against a payload-less constant still calls `dk_rc320_retain((DkE27_Tok){.tag = 84})`.
   Borrowing (no RC) for a value read from a container or parameter that isn't mutated while the
   value is live, and skipping RC for constants whose variant has no references, would remove most
   of the 13–18%. RC is also atomic everywhere, so a single-threaded compiler pays for atomics on
   every one of these.
2. *Allocation per node.* An `Expr` holds its `ExprKind` in a box, and every child `Expr` of a
   variant is boxed again: two allocations per node where Rust has one (`Box<Expr>` children,
   `ExprKind` inline). Boxing only the recursive edge (or the variant payload, not both) halves it.
3. *`match` on `str`* is a linear chain of `auk_str_eq` calls (`keyword()` is 10% of lexing).
   Dispatching on length and first byte, as rustc does, makes it a couple of compares. (Rewriting
   `keyword` as a lookup in a `{str: Tok}` constant gained ~4% of lexing time.)
4. *Building strings from chars.* Identifiers and literal text are `str(lx.chars[a..b])`, which
   goes through the runtime's string builder one char at a time (13% of lexing). A bulk
   chars-to-UTF-8 loop in `auk_str_from_chars` fixes it for every caller. (The port could also
   slice the source `str` by the same char indexes, `src[a..b]`, O(1) on ASCII text; 31 of the 102
   corpus files aren't ASCII.)

None of these needs the front end to change shape, and (1) and (2) are codegen changes that every
Auk program benefits from. Fixing (1)–(3) is worth an estimated 25–35% of the Auk time, which
would bring parsing to ~1.3x and lexing to under 2x of Rust.

## Go / no-go

**Go.** The rule: go if the Auk version is within ~2–3x of Rust and profiling shows a path to
closer. The Auk front end is 2.0x Rust on lexing + parsing (lexing 2.7x, parsing alone
1.6x), inside the band, without any tuning of the port: it is a line-by-line translation. The profile shows where the rest goes (RC on reads, double boxing, `str` match,
char-to-string building), and each has a known codegen or runtime fix (above). For Phase 3
planning: the whole corpus lexes and parses in ~50 ms in Auk, so the front end's speed will not be
what makes self-compilation slow.

Before Phase 3 starts, fix the gaps marked **(fix)** below; the rest are ergonomic and can be
lived with (the port did).

## Gaps found

### Language

1. **(fix) No `var` parameters in function types**, so a helper can't take a callback that
   mutates the parser. Rust's `list(close, what, |p| p.param())` and `nested(|p| ...)` are the
   parser's main combinators.
   ```
   fn apply(p: var P, g: (var P) => int!Diag): int!Diag = g(&p)?
   // error[E0023]: expected a type, found `var`
   ```
   The port spells every list as a loop over two helpers and every `nested` as save/restore
   (14 lists; each item parse lives in its own function so the flags are restored on error):
   ```
   while !p.list_end(token.RBrace) {
     let s = p.lift()
     let r = field_def(&p)
     p.restore(s)
     fields.push(r?)
     if p.list_sep(token.RBrace, "field")? { break }
   }
   ```
2. **(fix) No or-patterns.** `continues_after` is 54 arms of `X => true`; bracket handling, the
   item keywords in `recover`, `operand_ahead` and `peek_operand_ahead` are the same:
   ```
   A | B => true
   // error[E0020]: expected `=>` after the match pattern, found `|`
   ```
3. **(fix) Variant names across modules.** A bare variant of another module's enum resolves in an
   expression when the expected type is that enum (also through `if`, `match` and `return`), but
   not when it is `T?`, `T!` or `T!E`: `fn f(): tok.Tok? = Fn` is `error[E0102]: unknown name
   `Fn``. Nearly every lexer and parser function returns `T!Fail`, so they write `token.LParen`,
   `ast.ExprKind.Call(...)` everywhere (a script qualified ~440 sites). Worse, a bare `Float(x)`, `Int(n)`, `Str(s)`, `List`, `Map` silently resolves to
   core's `Value` variants:
   ```
   fn number(...): token.Tok!diag.Fail { ... Float(float.parse(str(s))!) }
   // error[E0200]: expected `Tok!Fail`, found `Value`
   ```
   Patterns are fine (the scrutinee's type decides). Either look through `T?`/`T!`/`T!E` for the
   expected enum, or allow importing an enum's variants (`use token.Tok.*`-like), or at least
   prefer the expected enum over core's `Value`.
4. **Keywords can't be field names, and there is no raw identifier.** `FnClause { uses, requires,
   ensures }` and `Param { var }` became `effects`, `pre`, `post`, `var_`.
   (`error[E0020]: expected a field name, found `uses``)
5. **`T!E` needs an enum `E`** (`error[E0112]`), so a struct error needs a one-variant wrapper:
   `enum Fail { Bad(d: Diag) }`, `enum Fails { Many(ds: [Diag]) }`, and `fail(diag.Bad(...))`.
6. **No unsigned or narrow integers.** `Tok::Int(u64)` keeps the bits in an `int`, with a
   hand-written overflow check (`parse_u64`) and printer (`uint_str`); spans are four `int`s
   (32 bytes) where Rust uses `u32`s (16), so every token and node is bigger.
7. **No `T??`** (`??` lexes as a hole), so `assign_op(): Option<Option<BinOp>>` became two
   functions (`is_assign`, `compound_op`).
8. Smaller: match guards must be pure, so the lexer's `'.' if self.eat('.') =>` arms became
   `if`/`else` chains (arguably clearer); no tuple assignment (`(a, b) = saved`); no hex format
   spec (`{n:x}` is E0282; `dump.auk` has its own `hex`).

### Library

9. **Char classes are ASCII-only** (`is_alpha`, `is_space`), but the lexer uses Unicode
   `is_alphabetic`, `is_alphanumeric`, `is_whitespace`. `lexer.auk` has exact White_Space and an
   approximate `is_alphabetic` outside ASCII (letters assumed except punctuation blocks). The corpus
   has no non-ASCII identifiers, so the diff can't show the difference; the plan's 1b item
   (Unicode tables) covers it.
10. Missing small helpers: `trim_end`, `strip_prefix`, `char.is_digit(radix)`, parsing with a
    radix (`u32::from_str_radix`), `min`/`max` of two ints.

### Performance cliffs

Measured with `compiler/bench/cliffs.auk` (built with `auk build`; 20k and 80k iterations):

11. **(fix) String building with `+=` is quadratic**: 6 ms for 20k one-char appends, 202 ms for
    80k, against 3 ms for 80k `parts.push(..)` + `join("")`. The port builds all output as
    `[str]` lines and joins once.
12. **(fix) No way to move a value out of a container.** Taking an element out, changing it and
    putting it back copies it, because the container still holds a reference:
    ```
    var g = items[n - 1]
    g.clauses.push(c)     // copies `clauses`: 49 ms for 20k pushes, 873 ms for 80k
    items[n - 1] = g
    ```
    Clause grouping does exactly this in Rust (`items.last_mut()`). The port keeps the open group
    in a local instead. In-place mutation itself is fine: `h.xs.push(x)` through a `var` parameter,
    `xs[0].push(x)` and `m[k].push(x)` are all O(1) (about 1 ms for 80k).
13. **Reads retain** and **double boxing** (profile items 1 and 2 above).
14. **Recursion depth and stack overflow.** Nested parentheses: the Rust parser handles 925 levels,
    the Auk one 359, so it uses ~2.6x the stack per nesting level (likely because every variable
    is a stack slot and aggregates such as `Expr` are passed by copy). Past the limit Rust aborts
    with "thread 'main' has overflowed its stack"; the Auk program dies of a bare SIGSEGV
    (exit 139) with no message unless it runs traced. The compiler needs a handler that reports
    "stack overflow" (the trace runtime already installs one on an alternate stack), smaller
    frames, or a bigger main-thread stack.

### Compiler bugs

None blocked the port; no compiler or runtime change was needed.

## Gaps closed (2d), and the rest

Closed before the Phase 3 freeze (tests in `tests/gaps.rs`):

- **1, 3: variants across modules.** The expected type picks a bare variant through `T?`, `T!`
  and `T!E` (`fn f(): tok.Tok!Fail = Eof`). A bare `Int`/`Float`/`Str`/... is never core's
  `Value` against another expected enum, nor when nothing is expected and an enum of the package
  has that variant: E0117, with a fix-it to `tok.Float`.
- **2: or-patterns** `A | B(x) =>` at the top of a match arm; every alternative binds the same
  names with the same types (E0267); exhaustiveness and reachability per alternative.
- **1: `var` parameters in function types**, `(var P) => T`; a closure's parameter is `var` when
  the type says so (`list(&p, q => q.item())`), and a function with `var` parameters can be
  passed for one. The Auk parser's type lists use it.
- **14: stack overflow** is a panic (`panic: stack overflow` at the function, exit 101; an `Err`
  under `catch` or in a task), and `main`, tests and tasks run on big stacks (256 MB / 32 MB): the
  Auk parser now takes over 10000 nested parentheses.
- **8, 10: small items**: tuple assignment `(a, b) = (b, a)`, `{n:x}`/`X`/`o`/`b` (E0283),
  `trim_start`/`trim_end`, `strip_prefix`/`strip_suffix`, `int.parse(s, radix)`,
  `c.is_digit(radix)`, `min(a, b)`/`max(a, b)`.

Deferred, with a recommendation:

- **4: keywords as field names / raw identifiers.** Don't add raw identifiers. If the self-hosted
  compiler really wants `uses`/`var` fields, allow a keyword as a field name only where a field
  name is expected (after `.`, in struct definitions, literals and patterns); otherwise keep the
  renamed fields (`effects`, `var_`), which cost nothing.
- **5: `T!E` with a struct `E`.** Worth doing after the freeze if wrappers keep appearing: it is a
  checker change (E0112) plus the error payload's type id, no syntax. The one-variant enum
  (`enum Fail { Bad(d: Diag) }`) is a fine workaround now.
- **6: unsigned/narrow ints.** Don't add them to the language. `int` with wrapping operators,
  `{n:x}` and radix parsing cover u64 bit patterns; compact spans are a layout optimization
  (packed fields) for later, not new types.
- **7: `T??`.** Don't add (`??` is the hole). Two functions or a small enum is clearer.
- **8: impure guards** (`'.' if self.eat('.') =>`): keep guards pure; `if`/`else` chains read better.
- **9: Unicode char classes**: library work, plan item 1b.
- **11–13: performance**, codegen/runtime only, no language change (numbers under "After 2d"):
  `s +=` appends in place when the string is unique; `var g = xs[i]` … `xs[i] = g` moves the
  element out and back; element reads that are only looked at are borrowed (no retain/release),
  field-less variants need no RC, `push` of a fresh value moves it; `match` on `str` is a table
  lookup; `str([char])` builds into one buffer. Double boxing is still open (see above).

## Phase 3

### 3a: types and module loading

| Rust (non-test lines) | Auk (`compiler/src/`) |
|---|---|
| `types.rs` (535) | `types.auk` (479, with the two unit tests as `test` blocks) |
| `resolve.rs` (498) | `resolve.auk` (532, with the manifest test) |
| `std::path`/`fs` bits, `cfg!(target_os)` | `paths.auk` (~170) |
| `check.rs` `visit_item_exprs`/`visit_expr`, `check/expr.rs` `as_path` | `visit.auk` (161) |
| `units.rs` `Units` ops (~60) | `units.auk` (+48) |
| `dump.rs` resolve mode (+260) | `dump.auk` (+250), `main.auk` |

The oracle is `auk dump resolve` (self-host-plan.md, Phase 3). `scripts/diff_resolve.sh`:
**254 files, 0 differ**, load diagnostics included (E0100, E0101 and parse errors in
submodules, from the corpus and `compiler/tests/resolve/`). It was at zero on the first full run;
the only bug during the port was the shadowing pitfall below. `auk test compiler` runs the
ported unit tests (4 pass). `diff_tokens`/`diff_ast` stay at 0 (254 files).

**Timing** (`scripts/pilot_time.sh 5 20`, now with a `resolve` row; best of 5; the machine was
shared with other agents' builds, so the absolute numbers are higher than the 2e table, the
ratios match it):

| measure | Rust | Auk | Auk / Rust |
|---|---|---|---|
| lex, in-process (per pass) | 19.1 ms | 52.8 ms | 2.76x |
| lex + parse, in-process | 52.2 ms | 114.5 ms | 2.19x |
| resolve (load each file's program), in-process | 839 ms | 1741 ms | **2.07x** |
| resolve + dump, whole process | 970 ms | 1909 ms | 1.97x |

A resolve pass loads 119 programs, each re-parsing the prelude (core is 134 items) and the
file's whole project and dependencies, so it is parsing: a `sample` of the Auk binary shows
`load_source` -> `add_module` -> `parse` and the lexer under nearly every stack, and nothing of the
loader's own (path handling, `realpath`, directory listing, map updates) above a few percent.
The ratio is the parser's.

### Gaps found

1. **No file embedding** (the 2c gap) now matters for the front end: Rust compiles the prelude
   in (`include_str!`); the Auk port reads `src/prelude/*.auk` at start-up from
   `$AUK_PRELUDE_DIR` or the checkout above the binary. Fine for diffing; an installed Auk
   compiler needs embedding (or a generated module of string constants).
2. **No `canonicalize`, current directory or OS name in the library.** The loader needs
   `Path::canonicalize` (project lookup, `same_file`), the current directory (the dump's relative
   paths) and `cfg!(target_os)` (`[link] macos`/`linux`). `paths.auk` binds C `realpath` and
   `uname` through FFI, so `compiler/` declares `effects = ["ffi"]` and every loading function
   `uses ffi`. Small core additions would remove that: `fs.canonical(path): str?`,
   `env.cwd(): str`, `env.os(): str`.
3. **`Err` has no error code.** Diagnostics quote Rust's `io::Error` (`No such file or directory
   (os error 2)`); the runtime keeps `errno` in `AukErr.code` but Auk can only `show` an `Err`,
   so `paths.io_error` maps the `strerror` text back to the number for the usual read errors.
4. **Pitfall: a module function silently takes over a core method of the same signature.**
   `paths.auk` had `pub fn starts_with(p: str, base: str): bool` (Rust's `Path::starts_with`);
   inside that module every `s.starts_with("/")` then called it instead of core's, recursing
   until `panic: stack overflow`. This is the spec's rule (a module's own names shadow core's),
   so not a bug, but nothing warns. The port renamed them (`is_under`, `strip_base`). A warning
   when a module function shadows a core function with the same parameter types would catch it.
5. **Collecting visitors.** Rust's visitors take an `FnMut` that pushes into a captured `Vec`;
   an Auk closure can't update a captured variable, so `visit_expr` pushes every expression onto
   a `var [ast.Expr]` (one retain per node), and the caller walks the list. `(var S, Expr) => ()`
   callbacks would also work; the list is simpler and was fast enough here.
6. Smaller: Rust's `BTreeMap`s are Auk maps (insertion order) iterated through
   `sorted_keys(m)`; Rust's `read_file(f).ok()` can't be `read_file(f) else none` (the
   fallback must be a `T`: E0201), so it is a `match`; `Ty::units()` is
   `units_of` so that it doesn't read like the `units` module.

No compiler or runtime bug blocked the port; no compiler or runtime change was needed.

### 3b: the type checker

| Rust (non-test lines) | Auk (`compiler/src/`) |
|---|---|
| `check.rs` (2086) | `check.auk` (2390, of which ~110 one-line forwards, see gap 1) |
| `check/expr.rs` (3835) | `check_expr.auk` (2134, up to `fail_call`) + `check_ops.auk` (2001, from `place`) |
| `check/pat.rs` (482) | `check_pat.auk` (496) |
| `check/shapes.rs` (633) | `check_shapes.auk` (671) |
| `typed.rs` (662, half docs) | `typed.auk` (339) |
| `ffi.rs` (551: prototypes, `conv`) | `cffi.auk` (549, with its test) |
| `units::erase`, `diag::json_report_files`, `Ty`'s derived `Ord`, `ast::type_dump` | `units.auk` (+110), `diag.auk` (+69), `types.cmp` (+70), `ast.auk` (+20) |
| `dump.rs` check/typed modes (+420) | `dump.auk` (+420), `main.auk` |

patterns.rs (exhaustiveness), effects.rs and holes.rs are not ported (the next step): `check.rs`
produces all its own diagnostics without them; `check_all` runs them only after the types
check clean.

**Oracles.** `auk dump check <file>` is the `auk check --json` report of the checker proper
(`check::check_types`: types, inference, overloading, shapes), i.e. without the patterns.rs and
effects.rs passes; once those are ported the oracle becomes `auk check --json` itself.
`auk dump typed [--core] <file>` prints the checker's errors and the typed program MIR lowering
will consume (units erased, as `check::check` returns it): definitions, every function's
signature, kind, callees, `old` captures and `result` local; constants and tests; for the focus
module a line per node with every side-table fact (type, coercions, name, binding, variant,
call with callee/type arguments/by-ref args, field, struct literal/pattern, closure, `?`,
`fail`, `else`, `?.`, `await`, `for`, format spec, show, value-map and error-payload patterns,
units) and the locals; every instance with its resolved targets; `types_used`, shape
implementations, `from_value` implementations and vtables. `--core` adds core's tables (diffed
once). Unit test: `dump::tests::typed_dump`. The Auk driver takes `compiler check --json <file>`
and `compiler typed [--core] <file>`.

**Corpus.** The golden corpus has few checker errors, so `tests/checker/` adds 662 small
programs extracted from the Rust integration tests' string literals (`tests/*.rs`) and the
`docs/errors/*.md` examples, plus `tests/checker/ffi_project/` (casts `"(T)"` and `"#embed path"`
prototypes in a project with the `ffi` effect): they hit nearly every checker code (E0102-E0370, with notes and
fix-its) and the parse/lex codes, standalone (no project).

```
check: 924 files, 0 differ
typed: 924 files, 0 differ        (typed --core: 0 differ)
tokens / ast / resolve: 924 files, 0 differ
```

Like the earlier phases this was at zero on the first full run: the port is line by line (three
of the five files were written in parallel against one shared header of signatures), and the
one design rule that made that work is in gap 1.

**Timing** (`scripts/pilot_time.sh 3 10`, 119 files / 955 KB, tests/checker/ left out; best of
3; "check alone" is check minus resolve, so it is the checker on every program the corpus files
load, prelude and dependencies included):

| measure | Rust | Auk (as ported) | Auk / Rust | Rust | Auk (3 fixes below) | Auk / Rust |
|---|---|---|---|---|---|---|
| resolve, in-process (per pass) | 796 ms | 1658 ms | 2.08x | 870 ms | 1779 ms | 2.04x |
| check (load + check), in-process | 2580 ms | 4865 ms | 1.89x | 2790 ms | 4242 ms | **1.52x** |
| check alone (difference) | 1784 ms | 3207 ms | 1.80x | 1919 ms | 2463 ms | **1.28x** |
| typed + dump, whole process | 2801 ms | 5542 ms | 1.98x | 2791 ms | 4676 ms | 1.68x |

(Two runs of the script; the machine was shared with other agents' builds, so compare ratios.
tokens and ast stay at 2.6x and 2.0x.)

The checker is closer to Rust than the parser is: it is mostly map lookups, unification and
small allocations, where Rust also allocates (`Ty` is boxed there too).

**Profile** (`sample`, check of examples/ and packages/, as ported): of the checker's time,
inference (`expr_inner` and below) ~34%, `finish_body` 25%, monomorphization
(`process_instance`) 22%, collection 8%, `lines` 7%. Three cliffs, each fixed in the port
without changing its shape (the second commit after the port):

1. *`finish_body` copied each body's tables* (`auk_arr_make_unique`, `auk_map_set`): `var t =
   cx.t` shares the maps with `cx`, so the first write copies them (the pilot's "moving out of a
   container" gap, 12); and `c.tables[m].locals[l].ty = fix_ty(.., c.tables[m].locals[l].ty)`
   copied the module's whole `locals` list per body, because the read on the right still holds a
   reference while the store needs the list unique (gap 13, "reads retain", with a worse effect:
   O(n) per store instead of an RC pair). Fix: update `cx.t` in place, read into a local before
   storing, and write only types that still contain variables. 25% -> 15% of the checker.
2. *`any_ty` allocated*: `children(t)` builds a list per node, and every `has_vars`/`has_error`/
   `has_params`/`has_units` walks the type through it (`use_type` asks four per type, recursively:
   11% of the time). A `match` instead of the list, and `resolve` returning a type without
   variables as is instead of rebuilding it.
3. *`lines(src)` per clause*: Rust's `src.lines().nth(k)` is lazy; the port split the whole
   module for every clause without a return type (`params_close`, 7%). Each module is split once.

What remains is spread out: RC traffic on `Ty`/`Expr` values (`dk_rc*`), `auk_map_set`/
`auk_map_get_opt` for the side tables (Rust's `HashMap` inserts are cheaper than the runtime's
maps with RC'd keys), and `expr_ids` re-walking each body's AST per instance (Rust does the same
walk with a closure, without building a list).

### Gaps found (3b)

1. **A dot call only looks in the current module, the receiver type's module and core**, so
   methods of one type can't be split across files: `check.rs`'s `impl Checker` is spread over
   four Rust files, and in Auk a function in `check_ops.auk` taking `var Checker` can't be reached
   as `c.place(..)` from `check_expr.auk`. The port keeps Rust's files and puts a one-line forward
   for every method of the other files in `check.auk` (the type's module), which `c.f(..)` finds
   from everywhere (~110 forwards). A rule like "a package's modules may extend a type of the
   package" (or `impl`-like grouping) would remove them. The alternative, one 9000-line module, also
   works.
2. **Moving out and reads retain** (pilot gaps 12, 13) cost more in the checker than in the
   parser: the table copies above. Every `var x = s.field` followed by mutation is a copy unless
   `s` dies first, and `a[i] = f(a[i])` copies `a`. Both are easy to write by accident; a warning,
   or the compiler moving a value out of a dying local, would help.
3. **No labelled `continue`/`break`** (`continue 'methods` in `find_impl`): a flag.
4. **No `{:?}`**: the checker's fix-its quote strings and chars Rust-style (`"\"x\""`); the port has
   a `debug_str` helper (exact for ASCII and the usual escapes, not for Unicode Rust escapes as
   non-printable).
5. **`T??`** again (pilot gap 7): `ffi.rs`'s `PtrOf` returns `Option<Option<CTy>>`; the port uses a
   three-variant enum (`NotPtr`/`AnyPtr`/`CType`), which reads better anyway.
6. **No target architecture**: `ffi.rs` asks `cfg!(target_arch)` for plain `char`'s signedness;
   the port assumes signed (right on macOS and Linux x86_64, wrong on Linux arm64) because asking
   the OS needs `uses ffi` everywhere. An `env.arch()` next to the wanted `env.os()` (3a gap 2).
7. Smaller: keyword field names again (`FnInfo.uses` is `effects`); `u64` literal bits in an `int`
   (pilot gap 6: overflow checks become `n < 0`); Rust's `HashMap`-ordered loops all feed
   order-independent code (`similar` breaks ties by name), except `check_duplicate_fns`, whose
   order only matters for three same-signature definitions at one position; the port iterates
   names sorted.

No compiler or runtime bug blocked the port; no compiler or runtime change was needed.

### 3c: patterns, effects, holes and `auk check`

| Rust (non-blank lines) | Auk (`compiler/src/`) |
|---|---|
| `patterns.rs` (896) | `patterns.auk` (954) |
| `effects.rs` (607) | `effect_check.auk` (701) |
| `holes.rs` (662, with its JSON via `json.rs`) | `holes.auk` (600) |
| `check::check_all`/`check_partial`, `main.rs` `check_file` | `check.auk` (+22), `cli.auk` (36) |

The rest of the checker: exhaustiveness and reachability (Maranget's usefulness, or-pattern
alternatives reported on their own), the effects analysis (direct and hidden effects, call
chains, E0410-E0415 with their combined fix-its), and `auk holes` (scopes at each hole, the
brief, the JSON). `check_all` sorts and deduplicates their diagnostics after a clean type check,
as Rust does. The driver now has `compiler check [--json] <file>` and `compiler holes [--json]
<file>`, with `auk check`'s and `auk holes`'s stdout, stderr and exit code (the text mode
renders with the `Diag::render` the fmt port brought).

**Oracles.** The commands themselves: `scripts/diff_check.sh` (`check <file> --json`),
`scripts/diff_check_text.sh` (`check <file>`: the rendered diagnostics on stderr) and
`scripts/diff_holes.sh` (`holes <file>` and `holes <file> --json`) each compare stdout, stderr and
the exit code (`scripts/pilot_common.sh`, `diff_cmd`). The corpus gained `tests/checker/pat_*`,
`eff_chains`, `hole_scopes`, two projects (`effects_project/`: E0413 against `effects = ["net",
"time"]`, shapes and generic instances across modules; `effects_none/`: E0413 against `effects =
[]`, holes with errors) and 14 programs the Rust tests run through `auk check`/`auk holes` that
weren't in it yet (found by logging what `check_file` and `holes::run` read during `cargo test`).

```
check:      959 files, 0 differ     (auk check --json)
check_text: 959 files, 0 differ     (auk check)
holes:      959 files, 0 differ     (auk holes)
holes_json: 959 files, 0 differ     (auk holes --json)
tokens / ast / resolve / typed: 959 files, 0 differ
```

All four were at zero on the first full run, as in the earlier phases. One divergence was found
by reading rather than by the corpus: the ported `render` showed an empty line for a diagnostic
at line 0 where Rust's `lines().nth(0.saturating_sub(1))` shows the first line (fixed, with a
test; no corpus file has such a diagnostic).

**Timing** (`scripts/pilot_time.sh 3 10`, new rows; 119 files, tests/checker/ left out; best of
3; the machine was shared with other agents' builds):

| measure | Rust | Auk | Auk / Rust |
|---|---|---|---|
| check (type checker), in-process | 2796 ms | 3624 ms | 1.30x |
| check alone (difference with resolve) | 1908 ms | 2246 ms | 1.18x |
| **`check_all`** (all of `auk check`), in-process | 3083 ms | 4331 ms | **1.40x** |
| patterns + effects (difference) | 287 ms | 707 ms | 2.47x |
| `auk check --json`, one process per file | 6159 ms | 5350 ms | 0.87x |

The two new passes are slower relative to Rust than the type checker, but they are a sixth of
the port's check time. A `sample` puts ~85% of them in effects (`check_fn`: collecting each
body's nodes, then `needs` per node: map lookups, small sets as sorted lists, the `Via` with its
callee name), mostly in malloc/free and RC traffic; patterns is small. Per process the port is
faster than Rust: the Rust binary loads LLVM at start-up, which is most of a small file's check.

### Gaps found (3c)

1. **A module name reserves the identifier project-wide** (fmt gap 2) hit harder: a module
   `effects` broke `parser.auk` and the checker, which have locals named `effects`, so the port
   is `effect_check.auk`; in `holes.auk` the local `holes` became `hs`.
2. **Keyword field names** again: `FnBrief.requires`/`ensures` are `pre`/`post` (as `FnClause`).
3. **No ordered set**: Rust's `BTreeSet<String>` (effects) is a sorted list without duplicates
   with three helpers (`set_of`, `set_union`, `set_subset`); `HashSet`s are `{K: bool}`.
4. **Closures can't update captured state**: Rust's `show_args` closure (it threads the set of
   names used) is a method taking `var Names`, and `Walk`'s `arms.iter().any(|a| self.expr(..))`
   is a loop; `Option<Option<usize>>` (`T??`) is an enum `Reach { Live, Dead(int?) }`.
5. **No print without a line break** (fmt gap 1): rendered diagnostics and hole briefs end with
   one, so they are printed with it stripped.
6. Smaller: `holes::offset` works on byte offsets; the port counts chars (same results on any
   text); Rust's `{:?}` of a test name is `check_expr.debug_str` (now `pub`).

No compiler or runtime bug blocked the port; no compiler or runtime change was needed.
### 3c: MIR lowering

| Rust (lines) | Auk (`compiler/src/`) |
|---|---|
| `mir/progen.rs` (2204) | `mir/progen.auk` (2415) |
| `mir/lower.rs` (4116) | `mir/lower.auk` (4238) |
| `mir/lower/pat.rs` (395), `lower/ffi.rs` (215) | `mir/lower/pat.auk` (410), `mir/lower/ffi.auk` (237) |
| `build.rs` `generate`, `dbg_tables`, imprints (~330) | `mir/build.auk` (~560, with `compiler ir`) |
| `mir/mod.rs` `impl Ex`, `Body`, `retype` (~200) | `mir.auk` (+185) |
| `mir/types.rs` `TyInfo::new`, `needs_rc`, ... (~80) | `mir/types.auk` (+95) |

The MIR data model, layouts, reader and printer are the back-end port's (`mir.auk`,
`mir/types.auk`, `mir/layout.auk`, `mir/printer.auk`, cherry-picked from its branch with the
Rust names); the lowering adds to them rather than defining its own. `compiler ir` lowers and
prints with that printer.

**Oracle.** `scripts/diff_ir.sh`: the back end's corpus (every program `auk ir` takes) plus
`compiler/tests/ir/` (closures with `var` function parameters and unpacked tuples; or-patterns,
tuple assignment, `str` match tables, `+=`, `str(cs[a..b])`, take/put-back, the fused map
update, tail calls; tasks, `await` of tuples/lists/`any`, cancel, `catch`, channels, typed
errors; `any S`, derived and user Ord/Eq/hash/`to_value`/`from_value`, boxed recursive fields,
contracts with `old`/`result`, `peek`, imprints; an FFI project with sqlite out-parameters and
lists, casts, `#embed` and a C function pointer), each as `auk ir`, `--release`, `--release -g`,
`--trace=json` and `--debug`: **1045 outputs (209 programs), 26 imprint helper programs, 0
differ**. It was at zero on the first full run except for the 4 programs whose imprints fail
at compile time (E0115, E0420), which needed the helper's exit code and stderr in the records
hook. The compiler's own MIR (`compiler/src/main.auk`, 7.9 MB) is identical too.

**Imprints.** `imprint X = e` runs a helper program at compile time (JIT, forked). The port
builds the same helper (`imprint_program`, diffed) and interprets its records
(`imprint_results`), but can't run it until it has a back end: the diff takes the records from
the Rust run (`AUK_IMPRINT_RECORDS`). Phase 4 replaces that with the port's own JIT.

**Timing** (`scripts/ir_time.sh 3`: the 209 programs, best of 3 each, summed; Rust lowering is
`AUK_TIME_LOWER=1 auk ir`, from the imprints' values to the finished program; the port's is
`compiler ir --time --quiet`, the same span; the machine was shared with other agents):

| measure | Rust | Auk (as ported) | Auk / Rust |
|---|---|---|---|
| lower, in-process (sum of 209) | 9933 ms | 15279 ms | **1.54x** |
| `ir`, whole process (load, check, lower, print) | 30384 ms | 36031 ms | 1.19x |

(The whole-process Rust number includes JIT-running the imprint helpers, which the port reads
from the records instead, and the port's checker is 1.28x; so the 1.19x flatters it a little.)
Not profiled or tuned yet: the port is a line-by-line translation, and the obvious suspects
are the ones of 3b (RC traffic on `Ex`/`Ty` trees, map lookups keyed by `Ty`, `struct_layout`/
`enum_layout` rebuilt per call as in Rust, where they are cheaper).

### Gaps found (3c)

1. **`lw.g.f(..)` and ownership.** Rust's `Lower` borrows `&mut Gen`; an Auk struct holding the
   `Gen` by value shares its lists with the caller's, so the first write would copy the whole
   program per instance. `emit_instance` moves the state in with `progen.take(&g)` (copy, then
   overwrite the caller's with empties) and back out at the end. Every `Gen`/`Lower` function
   takes `var` (a pointer), even read-only ones, so no call copies the ~25-field state.
2. **Closures can't change what they capture**, and Rust's `helper(kind, t, .., |g, f| ..)`
   closures and `both`/`obj`/`field`/`kid`/`check` helpers mutate a `Body` and the `Gen`:
   `helper` takes a `(var Gen, int) => Body` (fine), the others became module functions with
   the captured values as parameters (`derive_fromv`'s eight closures share a `FromV` struct).
3. **Effects are transitive**: reading an `#embed` file in `lower/ffi.rs` would make the whole
   lowering `uses fs`; the port reads every `#embed` file up front (`build.embeds`).
4. **`TyInfo`'s `RefCell` memo** (`needs_rc`) lives in `Gen.rc`, passed `var`.
5. Smaller: `ensures`/`requires` are keywords (`ensures_`, `requires_`); `Ex::int`/`bool`/
   `float`/`var` are `int_`/`bool_`/`float_`/`var_`; the `.0`-index of `x?.0`
   (`Ident::tuple_index`) is a digit check; a hex `u64` (`D` records) is decoded by hand
   (`int.parse(s, 16)` overflows past 2^63); `Program::live_keys` is a `Gen` field (the
   reader's `Program` has none).

No compiler or runtime bug blocked the port; the Rust side gained only the diff hooks
(`AUK_IMPRINT_RECORDS`, `AUK_IMPRINT_EVAL_IR`, `AUK_TIME_LOWER`).

## Phase 5

### fmt

| Rust | Auk (`compiler/src/`) |
|---|---|
| `fmt/mod.rs` (1599, of which ~100 the CLI) | `fmt.auk` (1812) |
| `fmt/doc.rs` (298) | `fmt/doc.auk` (308) |
| `fmt/tests.rs` (354, 25 tests) | `fmt/tests.auk` (346, the same 25 as `test` blocks) |
| `diag.rs` `render`/`severity`/`explain` (~40) | `diag.auk` (+55 with its test) |

`compiler fmt [--check] <file|dir|->...` is `auk fmt`: same output, messages (parse errors
rendered with `Diag::render`, "this is an auk fmt bug" for an output that doesn't round-trip)
and exit codes. The port is line by line; the differences in shape are listed at the top of
`fmt.auk`: a source position `(line, col)` is one `int` (`line << 32 | col`, so positions
compare and key maps as ints), `ast_shape` compares the `auk dump ast` text with spans and node
ids removed (Auk has no derived `Debug`), and the printer keeps finished lines plus the current
one instead of one `String` it truncates at every line break.

**Oracle.** `scripts/diff_fmt.sh` runs Rust `auk fmt -` and `compiler fmt -` on every `.auk`
under `tests/ examples/ packages/ src/prelude/ compiler/` (258 files, `.raft/` copies skipped)
and compares stdout, stderr and exit code, then feeds each successful output back to the same
formatter: **258 files, 0 differ, 0 not idempotent** (150 formatted, 108 parse errors, whose
rendered diagnostics match too). Zero on the first full run. `fmt --check` and in-place `fmt`
over whole directories also agree (same file lists, same rewritten files). `auk test compiler`
runs the 25 ported unit tests (30 tests in all pass).

**Timing** (`scripts/pilot_time.sh 7 20`, new last row; best of 7, alternating; the machine had
a load average of ~60 from other agents, so absolute numbers are high, ratios as in 3a):

| measure | Rust | Auk | Auk / Rust |
|---|---|---|---|
| lex + parse, in-process | 56.7 ms | 88.1 ms | 1.55x |
| `fmt --check` of the 119 files, whole process | 553 ms | 798 ms | **1.44x** |

`fmt --check` per file parses the input twice, formats, parses the output and compares the two
ASTs (`format_checked`). A `sample` of the port: parsing (all three) about half, `ast_shape`
37% (two AST dumps and the span stripping), laying out (`module`: building docs, rendering
each item to see if it is one line, `fits`) about a quarter, freeing ~12%. The formatter's own
logic is not the bottleneck; a cheaper AST comparison would be (Rust's `Debug` text is also
slow, but Auk's dump-and-strip is slower).

### Gaps found

1. **No print without a line break.** `print!("{out}")` is `print(out.strip_suffix("\n"))`
   (the output always ends with one); a `print_raw`/`write` for stdout would be cleaner.
2. **A module name reserves the identifier project-wide** (E0116): `var units` in `module()`
   clashed with the `units` module and became `us`. Adding a module to a project can break
   unrelated code with a local of that name.
3. **Child modules are reached only by their full path**, so `fmt.auk` writes `fmt.doc.Doc`,
   `fmt.doc.HardLine`, `fmt.doc.Fit.Flat` (~100 times) and has one-line wrappers for the
   `doc` constructors (Rust's `use doc::{...}`). No type aliases either (Rust's `Cmd`).
4. **`{` and `}` in strings are interpolation**, so every literal brace is doubled: `"{{"`,
   `bracketed("{{", "}}", ...)`, and all the test sources (converted by a script).
5. **No structural equality modulo some fields / no `Debug`**: `ast_shape` goes through the
   dump (above).
6. **No `unreachable!`**: the arms Rust marks unreachable return a harmless value (`nil()`,
   `""`, `break`).

No compiler or runtime bug was hit; no compiler or runtime change was needed.

### raft

| Rust (`src/bin/`) | Auk (`raft/src/`) |
|---|---|
| `raft.rs` (492) | `main.auk` (552) + `res.auk` (17, `Error`/`Res`) + `paths.auk` (136; 148 with its test) |
| `raft/manifest.rs` (297, 3 tests) | `manifest.auk` (460, the same 3 tests) |
| `raft/toml.rs` (358, 3 tests) | `toml.auk` (371, the same 3) |
| `raft/semver.rs` (127, 3 tests) | `semver.auk` (123, the same 3) |
| `raft/sha256.rs` (65, 1 test) | `sha256.auk` (130: `auk fmt` puts each of the 64 constants on its own line) |

A separate Auk project, `raft/` (`auk build raft/src/main.auk -o raft`), with every command
(`new [--lib]`, `add [--path]`, `remove`, `install`, `list`, `help`, usage errors), the same
stdout, stderr and exit codes, the same in-place `raft.toml` edits (comments kept), a
byte-identical `raft.lock` and identical `.raft/` trees (including the stale-entry cleanup and
the copy-then-rename update). Line by line with the same names and order; the shape differences
are listed at the top of each file: `Res<T>` is `T!res.Fail`, paths are `str`s, the closures of
`list` and `new` are functions.

**Oracle.** `tests/raft.rs` runs against `$RAFT_BIN` when set: **10/10 pass** with the port.
`scripts/diff_raft.sh` runs one scenario with each binary in the same directory (91 commands:
help and usage errors, every `new` error, adds with transitive deps, effect violations direct and
transitive, version mismatches, missing packages, path deps and their errors, a dependency cycle,
two sources for one package, stale/hidden/symlinked entries in `.raft/`, a modified installed
package, a tampered lock, a regenerated lock, 13 malformed manifests and locks, the repository's
`packages/` from the default registry, and a copy of `examples/live-site` with its committed,
stale lock and then a new one) and compares each command's stdout, stderr and exit code and the
SHA-256 of every file in the tree after it: **0 differ**, on the first full run.

**Timing.** Commands are dominated by process start and file I/O: `raft install` of
`examples/live-site` (7 packages) from nothing takes 27 ms (Rust) vs 43 ms (Auk), a no-op
install 18 vs 32 ms (10 runs each, `rm` included). The port's SHA-256 works on `[int]` bytes.

### Gaps found (raft)

1. **No current directory or executable path in core.** `paths.cwd()` is C `realpath(".")`
   (as in `compiler/src/paths.auk`), and the executable is `argv[0]` looked up in `$PATH`
   (`std::env::current_exe` has no equivalent), so raft needs the `ffi` effect.
2. **No build-time constants.** Rust bakes the checkout's `packages/` in (`env!("CARGO_MANIFEST_DIR")`);
   the port finds the checkout upward from its executable (a directory with `packages/` and
   `src/prelude/core.auk`). A port binary copied outside the checkout needs `RAFT_REGISTRY`.
3. **Filesystem:** no `copy`, no recursive remove, no way to tell a symbolic link (`is_dir`
   and `exists` follow links), no permissions. `paths.remove_all` recurses itself and spots a
   link by comparing `realpath`s, so a link in `.raft/` is removed, not followed (as Rust's
   `remove_dir_all`); `paths.copy` is `read_bytes` + `write_bytes` (Rust's `fs::copy` also
   copies the mode, which only matters for executable files). `fs` errors read `fs.read <path>:
   <strerror>`; Rust's `io::Error` text (`... (os error 2)`) comes from a table (`io_error`).
4. **No code sharing between projects without installing.** `paths.auk` is copied from
   `compiler/src/`, and SHA-256 is ported rather than taken from `packages/hash`: raft is the
   tool that fills `.raft/`, so it must build without one.
5. **No nested or-patterns**: `["help" | "--help"]` is E0020; written `["help"] | ["--help"]`.
6. **`uses` is a keyword**, so Rust's `uses(effects)` is `uses_note`.
7. **No dynamic width in a format spec** (Rust's `{head:width$}`): padded by hand.
8. **Core `trim`/`trim_start` are ASCII-only**; `manifest.auk` has `utrim`/`utrim_start` over
   Unicode White_Space for Rust's `str::trim` (the `[deps]` editor), and `is_whitespace` for
   `[link]` names.
9. **No `Result::ok()` on a `T!E`**, and `x else none` (E0248's own suggestion) is typed `str`, not `str?`,
   when nothing expects a type (`(checksum(d) else none) == want` is E0201): a small `ok_sum`
   helper with a `match`.
10. Smaller: `T!E` still needs an enum (`enum Fail { Bad(e: Error) }`, as in fmt); version
    components are `int`, so one above 2^63 - 1 is rejected where Rust's `u64` takes it.

No compiler or runtime bug was hit; no compiler or runtime change was needed.

## Reproduce

```
scripts/diff_tokens.sh        # tokens: 959 files, 0 differ
scripts/diff_ast.sh           # ast: 959 files, 0 differ
scripts/diff_resolve.sh       # resolve: 959 files, 0 differ (254 before tests/checker/)
scripts/diff_check.sh         # check (auk check --json): 959 files, 0 differ
scripts/diff_check_text.sh    # check_text (auk check): 959 files, 0 differ
scripts/diff_holes.sh         # holes, holes_json: 959 files, 0 differ each
scripts/diff_typed.sh         # typed: 959 files, 0 differ, and typed --core
scripts/diff_tokens.sh        # tokens: 924 files, 0 differ
scripts/diff_ast.sh           # ast: 924 files, 0 differ
scripts/diff_resolve.sh       # resolve: 924 files, 0 differ (254 before tests/checker/)
scripts/diff_check.sh         # check: 924 files, 0 differ
scripts/diff_typed.sh         # typed: 924 files, 0 differ, and typed --core
scripts/diff_ir.sh            # ir: 1045 outputs (209 programs x 5 variants), 26 helpers, 0 differ
scripts/ir_time.sh 3          # the 3c timing table
scripts/diff_fmt.sh           # fmt: 258 files, 0 differ, 0 not idempotent
scripts/diff_raft.sh          # raft: 91 commands, 0 differ; tests/raft.rs against the port
scripts/pilot_time.sh 7 20    # the tables above
auk test compiler             # the ported unit tests
auk build compiler/bench/cliffs.auk -o /tmp/cliffs && /tmp/cliffs 80000
```
