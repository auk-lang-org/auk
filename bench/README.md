# Auk accuracy benchmark (card #488)

Auk is meant to need the fewest tokens AND give the highest accuracy for AI-written code. Tokens
were measured before (Auk about 11% smaller than Python over 10 programs). This benchmark measures
**accuracy**: given only the ~3k-token language reference, can a model write correct Auk as reliably
as it writes Python?

Results and the failure analysis are in [results.md](results.md).

## Layout

```
bench/
  bin/auk            the compiler, built once (cargo build --release) and frozen for the runs
  spec.md             snapshot of docs/spec.md (= `bin/auk spec`): spec v2, 10,097 chars, 3,198 o200k tokens
  tasks/NN_name/      20 tasks, see below
  harness/
    common.py         task loading, prompt template, model call, compile/test helpers
    verify.py         reference solutions pass every test in both languages; stubs fail them
    run.py            runs the three conditions, logs everything to runs/<name>/
    model_cmd.py      the AUK_HATCH_CMD used by `auk hatch` (same `claude -p` call, logged)
    report.py         tiktoken o200k token counts + per-task table -> runs/<name>/report.md
  run.sh              verify + run + report in one go
  runs/<name>/        raw prompts, replies, spliced programs, compiler/test output, results.json, report.md
```

Runs so far, spec v1 (2,996 tokens): `runs/run1` (claude-opus-5-5, the default `claude -p` model,
main run), `runs/run3-sonnet` (claude-sonnet-5-5) and `runs/run2-haiku` (claude-haiku-5-5). With spec
v2 (3,198 tokens, library signatures and idioms, card #519): `runs/run4-spec2` (opus),
`runs/run6-spec2-sonnet` and `runs/run5-spec2-haiku`.

## Tasks

Each `tasks/NN_name/` holds the same problem in both languages:

| file | content |
|---|---|
| `desc.md` | plain-English description (shared, word for word, by both languages) |
| `given.auk` / `given.py` | types the task provides (structs, enums / dataclasses, exception classes, a `catch` helper) |
| `stub.auk` / `stub.py` | signatures (with contracts in Auk) and placeholder bodies (`{ ?? }` / `raise NotImplementedError`) |
| `visible.auk` / `visible.py` | 1-6 asserts shown to the model |
| `tests.auk` / `tests.py` | the hidden tests used for scoring (a superset of the visible ones, with the edge cases) |
| `ref.auk` / `ref.py` | my reference solutions, written first; `harness/verify.py` checks they pass every test |

Auk errors are enum variants (`is err(Overdraft(2))`); in Python they are exception classes with the
same names and fields, checked with `isinstance` and attribute equality. Auk `T?` is Python
`Optional[T]`. The hidden tests assert the same things in both languages.

The 20 tasks: word_freq (maps, strings), palindrome (chars), rle (encode+decode, error enum),
parse_kv (parsing with positional errors), expr (recursive enum: eval with optionals + render),
bsearch (lower bound, optional), merge_intervals (tuples, sort), roman (to/from with canonical
validation), to_base (incl. the minimum 64-bit int), bank (structs, enums, errors), top_n (sort with
tie-break), group_by_len (map of lists, Unicode lengths), spiral (matrix edges), balanced
(stack), calc (tokenizer + 3 recursive-descent functions with a `var` cursor, 5 holes), csv
(quoted fields, error positions), primes (sieve, 2M), bst (recursive enum, 4 functions), wrap
(greedy word wrap with long words), date (strict YYYY-MM-DD validation, leap years).

## Conditions

All model calls are `claude -p --model <model> --output-format json --tools "" --setting-sources ""
--no-session-persistence`, run in an empty temp directory with a 300 s timeout: the same model for
everything, no tools (the model cannot run code or read the repo), and no user/project settings or
CLAUDE.md files.

1. **Auk one-shot (`auk1`)**: prompt = spec + description + given code + stub + visible tests
   (template in `harness/common.py`, `TEMPLATE`). The reply's first fenced block is spliced in place
   of the stub; the scored program is given + solution + visible + hidden tests. Recorded: compiles
   (`auk check`), all tests pass (`auk test`, contracts on), solution tokens, API output tokens.
2. **Auk + hatch (`hatch`)**: `auk hatch <file> --tries 3` on a file with the description (as `//`
   comments), the given code, the stub with its `??` holes and the visible tests. Hatch builds its own
   prompt (the spec, the file, the hole brief), type-checks and runs the visible tests, and feeds
   errors back up to 3 times per hole. Then the hidden tests are run on the hatched file. Recorded:
   hidden-test pass, number of model calls, tries per hole.
3. **Python one-shot (`py1`)**: the identical template with the Python parts and no spec ("You are
   writing code in Python 3.9" - the machine's python3 is 3.9.6). Recorded: syntax OK (`ast.parse`),
   all tests pass, tokens.

Tokens are counted with tiktoken `o200k_base` on the extracted code block, both raw and with blank
lines, whole-line comments and Python docstrings removed ("code" tokens, the headline number).

## Re-running

```sh
bench/run.sh my-run                    # verify tasks, run all 3 conditions x 20 tasks, write report
REBUILD=1 bench/run.sh after-spec-fix  # rebuild the compiler and re-snapshot the spec first
BENCH_MODEL=claude-haiku-5-5 bench/run.sh haiku --jobs 5
python3 -I bench/harness/run.py --tasks 15_calc,16_csv --conditions auk1 --out bench/runs/x
```

`run.py` needs only the system `python3` (run with `-I`); `report.py` needs a Python with
`tiktoken` (`BENCH_TOK_PY`). Note `auk hatch` uses the spec compiled into `bin/auk`; the one-shot
prompt uses `bench/spec.md` and `run.py` warns if they differ, so after editing docs/spec.md use
`REBUILD=1`.
