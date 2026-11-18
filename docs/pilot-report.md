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

## Reproduce

```
scripts/diff_tokens.sh        # tokens: 221 files, 0 differ
scripts/diff_ast.sh           # ast: 221 files, 0 differ
scripts/pilot_time.sh 7 20    # the table above
```
