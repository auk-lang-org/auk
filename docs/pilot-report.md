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
- **11–13: performance** (string `+=`, moving out of containers, RC on reads, double boxing) are
  codegen/runtime work tracked in 2d, not language changes.

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

## Reproduce

```
scripts/diff_tokens.sh        # tokens: 254 files, 0 differ
scripts/diff_ast.sh           # ast: 254 files, 0 differ
scripts/diff_resolve.sh       # resolve: 254 files, 0 differ
scripts/pilot_time.sh 7 20    # the tables above
auk test compiler             # the ported unit tests
```
