# Auk accuracy benchmark: results (card #488)

Methodology: see [README.md](README.md). Summary: 20 function-level tasks, with hidden tests that
mean the same thing in Auk and Python. There are three conditions: Auk one-shot from the 3k-token
spec, Auk through `auk hatch --tries 3`, and Python one-shot. Every call goes through `claude -p`
with no tools. First runs: compiler `bench/bin/auk` sha256 `b299308e…`, spec v1 of 9,653 chars and
**2,996 o200k tokens**. The spec-v2 re-run (next section) used compiler `07b543a2…` and the
3,198-token spec now in `bench/spec.md`. Raw prompts, replies, spliced
programs and compiler/test output are in `bench/runs/<run>/<task>/<condition>/`.

The main run uses the default `claude -p` model, **claude-opus-5-5**. It hit the ceiling: every
condition passed every task. So I also ran the same harness, unchanged, with claude-sonnet-5-5 and
claude-haiku-5-5. Each run uses one model for every call.

## Update (card #519): spec v2 with library signatures and idioms

Everything below this section describes the **first** runs (spec v1, 2,996 tokens). This section
describes the re-run after the spec gained the guidance suggested at the end of this file.

**What changed in `docs/spec.md`** (2,996 -> 3,018 tokens from other agents' edits, then -> **3,198
o200k tokens**, 10,097 chars; the snapshot benchmarked is `bench/spec.md`). Every addition was
checked against `src/prelude/*.auk` and by running small programs. (After these runs, another
agent's edit to the Modules paragraph about shadowing and E0116 brought `docs/spec.md` to 3,238
tokens, so about 40 tokens need trimming to get back under the 3,200 budget.)

- Arithmetic: "`/` and `%` truncate toward zero: `-7 / 2 == -3`, `-7 % 2 == -1`."
- Structs: `Point { x: 3.0, ..p }   // ..p comes last`.
- Control flow: `for c in s.chars() { }   // a str is not iterable`.
- Optionals: `m[k] = (m.get(k) else 0) + 1    // else binds loosest; ?? is only a hole`.
- Collections, now with signatures: `pop(): T?`, `first last min max: T?`, `reduce(init, f)`,
  `find(pred): T?`, `find_index: int?`, `counts(): {T: int}`, `group_by(key): {K: [T]}`, plus
  "`sort sort_by(key)`: stable sorted copies; tuples and lists compare element by element:
  `sort_by(p => (-p.n, p.name))`" and "maps: `remove(k): V? keys values entries`".
- Strings: `find(sub): int? (char index)`, `repeat(n)` (it existed but was undocumented), and
  "chars: `is_digit is_alpha is_space upper lower` (ASCII)". Verified: `'é'.is_alpha()` is false,
  `'é'.upper()` is `é`, `'٣'.is_digit()` is false, and `"Héllo".upper()` is `HéLLO`.
- One line: "Prefer these to hand-written loops."

Same 20 tasks, same harness and the same three models. The compiler was rebuilt once
(`bench/bin/auk`, sha256 `07b543a2…`; it includes other agents' compiler fixes made since the
first run) and frozen for all three new runs. Python was re-run too, which shows the run-to-run
noise on the unchanged condition (about ±3%).

| model | Auk pass@1 before -> after | Auk + hatch | hatch model calls (90 holes) | Auk solution tokens before -> after | Python before / after | **Auk / Python before -> after** | output tokens per one-shot call, Auk / Python, before -> after |
|---|---|---|---|---|---|---|---|
| opus-5-5 (run1 -> run4-spec2) | 20/20 -> 20/20 | 20/20 -> 20/20 | 30 -> 30 | 235.3 -> **195.9** (-17%) | 189.6 / 192.9 | **1.24 -> 1.02** | 620 / 317 (x1.96) -> 421 / 316 (**x1.33**) |
| sonnet-5-5 (run3 -> run6-spec2-sonnet) | 20/20 -> **19/20** | 20/20 -> 20/20 | 31 -> 32 | 230.8 -> **192.8** (-16%) | 177.4 / 171.3 | **1.30 -> 1.13** (1.17 without the failed task) | 618 / 308 (x2.01) -> 589 / 296 (x1.99) |
| haiku-5-5 (run2 -> run5-spec2-haiku) | **19/20** -> 20/20 | 20/20 -> 20/20 | 32 -> 34 | 233.0 -> **204.2** (-12%) | 180.9 / 179.6 | **1.29 -> 1.14** | 1,904 / 376 (x5.06) -> 1,531 / 478 (**x3.20**) |
| all three, pooled | 59/60 -> 59/60 | 60/60 -> 60/60 | 93 -> 96 | 233.0 -> **197.6** (-15%) | 182.6 / 181.3 | **1.28 -> 1.09** | |
| my references | | | | 179.2 | 158.7 | 1.13 | |

**Verdict: it worked for tokens. Accuracy is unchanged within noise.** Model-written Auk shrank
by 12-17% for every model, and the Auk/Python ratio fell from 1.24-1.30 to 1.02-1.14. That is now
at or below the 1.13 of my hand-written references, so the "defensive Auk" part of the gap is
mostly gone. What remains is structural (see below). Opus's reasoning overhead on Auk also fell
from 2x to 1.33x of Python, and haiku's from 5x to 3.2x. Sonnet's is unchanged (2x).

**Accuracy, honestly.** One-shot is 59/60 both before and after, but the one failure moved:

- *Fixed:* haiku 10_bank (`..acct` placed first) now compiles. No `??` defaults, no `for c in s`
  and no `let` maps appeared in any new answer.
- *New:* sonnet 13_spiral wrote `let rest = m[1..]`. Auk has no open-ended slices (E0021
  "expected an expression, found `]`"). It's a Python/Rust habit, and the spec shows only
  `xs[a..b]`. The answer was the shortest correct algorithm (84 tokens; Python 206). It is
  plausible that "prefer library calls" pushed it towards terser, Python-shaped code. Hatch fixed it
  in one call. The 84 tokens of this failed answer are inside sonnet's mean; without that task the
  ratio is 1.17.
- *Hatch retries (6 over 270 holes, was 3):* sonnet 03_rle (`if let_prev(prev)`, a garbled
  first fence that the model corrected in prose; hatch takes the first fence), haiku 04_parse_kv
  (`return err(MissingEq(i))` instead of `fail(...)`), haiku 17_primes (semicolons), haiku 15_calc
  (`int(c)?` on a plain `int`; `push` on a `let` list), and haiku 09_to_base try 1. **That last one
  is the first Auk answer in any run that compiled and then failed a test**: a sign error in
  `-(m % base)` for positive `n`, a logic bug of the kind Python answers make too. The visible test
  caught it and the retry passed. All hidden tests still pass: 60/60.
- With n = 20 per model and the pass rates at the ceiling, none of these differences are
  significant.

**Which failure modes disappeared.** I counted the 20 one-shot Auk answers per run (before ->
after, opus / sonnet / haiku):

| pattern | before | after |
|---|---|---|
| uses `sort`/`sort_by` | 0 / 3 / 2 | 3 / 3 / 3 (every task that sorts) |
| hand-written sort helper (`insert_sorted`, custom sort fn) | 2 / 0 / 1 | **0 / 0 / 0** |
| code-point arithmetic for case (`>= 65`, `+ 32`) | 1 / 1 / 1 | **0 / 0 / 0** |
| uses char/string helpers (`is_alpha is_digit lower upper`) | 1 / 2 / 3 | 5 / 4 / 5 |
| uses `pop()` | 0 / 0 / 0 | 2 / 1 / 1 |
| manual floor-division fix-ups in 09_to_base | 1 / 1 (digit-carry loop) / 0 | 0 / 0 / 0 (all use the non-positive trick, 120-131 tokens; ref 127) |

Per task (mean of the three models' one-shot Auk tokens, before -> after; Python is the mean of
all six Python runs):

| task | Auk before (o/s/h) | Auk after (o/s/h) | Python | refs Auk / Py |
|---|---|---|---|---|
| 01_word_freq | 73 (63/78/77) | 67 (63/63/74) | 57 | 58 / 52 |
| 02_palindrome | 165 (162/149/185) | **77** (43/58/131) | 78 | 54 / 50 |
| 03_rle | 322 (339/322/305) | 299 (300/311/285) | 233 | 281 / 230 |
| 04_parse_kv | 161 (197/131/155) | 132 (132/131/132) | 144 | 126 / 130 |
| 05_expr | 187 (171/212/179) | 186 (171/172/216) | 268 | 166 / 209 |
| 06_bsearch | 102 (103/103/101) | 102 (103/103/101) | 92 | 95 / 88 |
| 07_merge_intervals | 205 (242/125/247) | **124** (99/137/137) | 93 | 120 / 89 |
| 08_roman | 395 (405/405/376) | 395 (403/385/396) | 294 | 336 / 298 |
| 09_to_base | 188 (157/258/148) | **126** (126/120/131) | 110 | 127 / 92 |
| 10_bank | 165 (148/152/194) | 154 (150/160/152) | 125 | 139 / 107 |
| 11_top_n | 204 (231/165/217) | **67** (68/68/65) | 64 | 59 / 60 |
| 12_group_by_len | 150 (169/152/128) | **80** (66/66/108) | 78 | 102 / 68 |
| 13_spiral | 243 (234/254/241) | 186 (239/*84*/236) | 205 | 209 / 208 |
| 14_balanced | 138 (140/137/137) | 136 (123/142/143) | 81 | 107 / 75 |
| 15_calc | 732 (748/681/767) | **631** (631/632/631) | 659 | 609 / 588 |
| 16_csv | 270 (276/268/265) | 273 (275/284/259) | 224 | 243 / 211 |
| 17_primes | 148 (157/141/145) | 148 (157/141/145) | 118 | 112 / 115 |
| 18_bst | 217 (207/215/230) | 217 (216/206/229) | 317 | 194 / 175 |
| 19_wrap | 231 (204/284/206) | 227 (227/260/193) | 141 | 180 / 119 |
| 20_date | 365 (354/384/357) | 327 (326/334/321) | 258 | 266 / 209 |

(*84* = sonnet's non-compiling answer.) The wins are where a documented library call replaces a
loop: sorting (07, 11), case and char classes (02, and `is_digit` in 15's tokenizer), `/`/`%`
semantics (09), and `unique`/`group_by`/`keys().sort()` (12). Tasks that were already idiomatic loops (06, 16, 17, 18) didn't
move.

### Where Auk's remaining cost comes from

Are the tasks Python-favoured? Somewhat: my hand-written references are 13% larger in Auk. To
split that, I removed each syntactic feature from the code and counted again (o200k tokens, refs /
the three new model runs):

| cost | refs | model answers (spec v2) |
|---|---|---|
| lines holding only `}` | 4.0% of Auk | 4.5-4.8% |
| `var`/`let` keywords | 2.1% | 2.2-2.3% |
| type annotations on locals (`var out: [str] = []`) | 2.0% | 1.6-2.0% |
| ` {` at line ends | 0.9% | 1.1-1.2% |
| `requires` lines copied from the stub (Python gets them as docstrings, which aren't counted) | 1.1% | 1.0% |
| offset: Python's `return` keyword, which Auk doesn't need | -1.7% of Python | |

So about 8-9 points of the 13% are block and declaration syntax, and the rest is Python built-ins
that Auk lacks. Auk wins where it has sum types and pattern matching: 05_expr (-21%), 18_bst, and
now 15_calc and 04_parse_kv. Per task (refs):

- **19_wrap (+51%)**: Python `[w[i:i+width] for w in ... for i in range(0, len(w), width)]`. Auk
  needs a while loop with `if a < b { a } else { b }`, because there is no two-argument `min`/`max`
  and no range step. `w.chars().chunks(width).map(str)` exists, and no model (and not my ref)
  used it.
- **20_date (+27%)**: Python slicing + `int()` + chained `1 <= m <= 12` (Auk: E0026, chained
  comparisons are an error). `int.parse` accepts `+` and `_`, so strict digits need a hand loop in
  both languages, but Python's is a one-line `all(c in "0123456789" ...)`.
- **03_rle (+22%)**: `c * n` and `"".join(out)` vs `str(c).repeat(n)`, plus braces.
- **07_merge_intervals (+35%)**: `out[-1]` (three times) and `max(a, b)`. Auk has no negative
  index (it panics) and no two-argument `max`.
- **12_group_by_len (+50%)**: `dict.setdefault` and a dict comprehension over `sorted(groups)`.
  Auk needs get-else-`[]`, push, store back. The models' v2 answers (66 tokens) beat my ref by
  using `unique`/`sort`.
- **14_balanced (+43%)**: `c in "([{"`, a dict literal, and the truthiness `not stack`. Auk has
  `"([{".contains(c)`, but no `is_empty()`, and braces add up on short branches.
- **08_roman (+13%)**: a Python dict lookup with a default vs an Auk `match`. Auk parameters are
  immutable, so Python's `n -= v` becomes `var left = n`.
- **09_to_base (+38%)**: Python's `abs(n)` is safe on unbounded ints. Auk's 64-bit ints need the
  negative-accumulator trick to survive the minimum int. This cost is inherent and correct.
- **10_bank (+30%)**: every Python `Tx` class shares `.amount`, while each Auk enum variant needs a
  `match` to pull its field out.
- **17_primes**: `[True] * (n + 1)` vs a push loop (no list fill).
- **16_csv**: deep nesting, so mostly `}` lines.

### Recommendations

Library (small, high-yield; each removes a pattern that cost 5-30 tokens in these answers):
1. **Two-argument `min(a, b)` / `max(a, b)` for `Ord`** (the spec's shape example already shows
   one). It showed up in 07, 19 and 13.
2. **Open-ended slices `xs[a..]` / `xs[..b]`** (and `s[a..]`). Models write them anyway (the only
   new one-shot failure). Failing that, add one spec line: "slices need both ends; use
   `skip`/`take`".
3. A list fill (`[false].repeat(n)` or `list(n, v)`), and `is_empty()` for lists, maps and `str`.
4. A map upsert or default (`m.get(k) else []` + push + store is the 12_group_by_len cost), e.g.
   `m.update(k, d, f)`.
5. Perhaps a range step (`(0..n).step(k)`). `chunks` covers most uses if the spec shows it on
   chars.

Spec (only if the budget allows; it is at 3,198 for this run):
- Show `s.chars().chunks(n).map(str)` and "plain values convert to `T?` in match arms too". The v2
  roman answers still write `'I' => some(1)`.
- State that `split()` never yields empty pieces. The v2 answers still add
  `.filter(w => w.len() > 0)`.

Language (bigger decisions, listed for the record): optional chained comparisons
(`1 <= m <= 12`, now E0026), negative indexing or `xs.last()` assignment, and closing-brace cost.
Brace-only lines are about 4.5% of every Auk answer, but braces also buy the accuracy that the
whitespace-free format gives, so this is not a recommendation to change them.

**Not measured:** the reasoning-token drop for opus and haiku came from the same spec change, but
it is a single run per model. Treat 1.33x and 3.2x as indicative.

## Headline numbers (spec v1, first runs)

| run (model) | Auk pass@1 | Auk + hatch (hidden tests) | Python pass@1 | hatch model calls (holes = 30) | mean solution tokens Auk / Python | API output tokens per one-shot call, Auk / Python |
|---|---|---|---|---|---|---|
| run1 (opus-5-5) | **20/20** (compile 20/20) | **20/20** | **20/20** | 30 (no retries) | **235.3 / 189.6 (Auk +24%)** | 620 / 317 (x1.96) |
| run3 (sonnet-5-5) | 20/20 (compile 20/20) | 20/20 | 20/20 | 31 (1 retry) | 230.8 / 177.4 (Auk +30%) | 618 / 308 (x2.01) |
| run2 (haiku-5-5) | 19/20 (compile 19/20) | 20/20 | 20/20 | 32 (2 retries) | 233.0 / 180.9 (Auk +29%) | 1,904 / 376 (x5.06) |
| my reference solutions | - | - | - | - | 179.2 / 158.7 (Auk +13%) | - |

Solution tokens are tiktoken o200k counts of the code block, without blank lines, whole-line comments
and Python docstrings. The raw counts, which keep them, are in the tables below. API output tokens
come from `claude -p`'s usage and include any hidden reasoning.

**Accuracy.** On these tasks a model writes correct Auk from the spec alone about as reliably as
it writes Python. Across the three models, 59/60 Auk one-shots passed and 60/60 Python one-shots
passed. With hatch, Auk passed 60/60. Four Auk answers in total were wrong (1 one-shot answer and
3 hatch tries), and **all four were rejected by the type checker**. No Auk
answer compiled and then failed a test, hidden or visible. Hatch fixed each of its errors from the
diagnostics alone: 3 extra calls over 90 holes. With Opus, hatch never needed a second try.

**Tokens are the problem this benchmark actually exposes.**
- Model-written Auk is **24-30% larger than model-written Python** for the same function. That
  goes against the earlier "11% smaller" result, which compared whole programs. My idiomatic Auk
  references are also 13% larger than my Python references on these small functions, because Python's
  comprehensions, slicing, `sorted(key=)`, `max()` and `setdefault` are hard to beat. Most of the
  rest of the gap (13% -> 24-30%) is the model writing **defensive, non-idiomatic Auk**: hand-rolled
  insertion sorts, code-point arithmetic for case folding, and its own `index_of` loops. It avoids
  library calls whose exact behaviour the spec doesn't state (details below).
- The models also **spend 2x (opus, sonnet) to 5x (haiku) more output tokens** producing an Auk
  answer than a Python one, although the visible replies are about the same length. The extra is
  reasoning about the unfamiliar language. For haiku, $ per correct Auk function is far higher
  than for Python.

## Per-task tables

Columns: Auk one-shot result; Auk + hatch hidden-test result (model calls, holes filled); Python
one-shot result; one-shot solution tokens as code (raw); and my reference solutions' code tokens,
Auk / Python.

### run1: claude-opus-5-5 (main run)

| task | Auk one-shot | Auk + hatch (model calls) | Python one-shot | Auk tokens code (raw) | Python tokens code (raw) | reference tokens Auk / Py |
|---|---|---|---|---|---|---|
| 01_word_freq | pass | pass (1 call) | pass | 63 (63) | 56 (56) | 58 / 52 |
| 02_palindrome | pass | pass (1 call) | pass | 162 (162) | 157 (157) | 54 / 50 |
| 03_rle | pass | pass (2 calls, 2/2 holes) | pass | 339 (339) | 236 (248) | 281 / 230 |
| 04_parse_kv | pass | pass (1 call) | pass | 197 (197) | 137 (152) | 126 / 130 |
| 05_expr | pass | pass (2 calls, 2/2 holes) | pass | 171 (171) | 266 (267) | 166 / 209 |
| 06_bsearch | pass | pass (1 call) | pass | 103 (103) | 92 (92) | 95 / 88 |
| 07_merge_intervals | pass | pass (1 call) | pass | 242 (242) | 94 (94) | 120 / 89 |
| 08_roman | pass | pass (2 calls, 2/2 holes) | pass | 405 (405) | 266 (278) | 336 / 298 |
| 09_to_base | pass | pass (1 call) | pass | 157 (173) | 124 (135) | 127 / 92 |
| 10_bank | pass | pass (1 call) | pass | 148 (148) | 131 (140) | 139 / 107 |
| 11_top_n | pass | pass (1 call) | pass | 231 (231) | 63 (71) | 59 / 60 |
| 12_group_by_len | pass | pass (1 call) | pass | 169 (169) | 76 (76) | 102 / 68 |
| 13_spiral | pass | pass (1 call) | pass | 234 (234) | 203 (203) | 209 / 208 |
| 14_balanced | pass | pass (1 call) | pass | 140 (140) | 84 (84) | 107 / 75 |
| 15_calc | pass | pass (5 calls, 5/5 holes) | pass | 748 (748) | 656 (699) | 609 / 588 |
| 16_csv | pass | pass (1 call) | pass | 276 (276) | 219 (230) | 243 / 211 |
| 17_primes | pass | pass (1 call) | pass | 157 (157) | 117 (117) | 112 / 115 |
| 18_bst | pass | pass (4 calls, 4/4 holes) | pass | 207 (207) | 356 (383) | 194 / 175 |
| 19_wrap | pass | pass (1 call) | pass | 204 (204) | 143 (151) | 180 / 119 |
| 20_date | pass | pass (1 call) | pass | 354 (354) | 315 (315) | 266 / 209 |

### run3: claude-sonnet-5-5

| task | Auk one-shot | Auk + hatch (model calls) | Python one-shot | Auk tokens code (raw) | Python tokens code (raw) | reference tokens Auk / Py |
|---|---|---|---|---|---|---|
| 01_word_freq | pass | pass (1 call) | pass | 78 (78) | 61 (61) | 58 / 52 |
| 02_palindrome | pass | pass (2 calls) | pass | 149 (149) | 41 (41) | 54 / 50 |
| 03_rle | pass | pass (2 calls, 2/2 holes) | pass | 322 (322) | 229 (241) | 281 / 230 |
| 04_parse_kv | pass | pass (1 call) | pass | 131 (131) | 137 (152) | 126 / 130 |
| 05_expr | pass | pass (2 calls, 2/2 holes) | pass | 212 (212) | 297 (298) | 166 / 209 |
| 06_bsearch | pass | pass (1 call) | pass | 103 (103) | 92 (92) | 95 / 88 |
| 07_merge_intervals | pass | pass (1 call) | pass | 125 (125) | 92 (92) | 120 / 89 |
| 08_roman | pass | pass (2 calls, 2/2 holes) | pass | 405 (405) | 292 (304) | 336 / 298 |
| 09_to_base | pass | pass (1 call) | pass | 258 (258) | 123 (134) | 127 / 92 |
| 10_bank | pass | pass (1 call) | pass | 152 (152) | 111 (120) | 139 / 107 |
| 11_top_n | pass | pass (1 call) | pass | 165 (165) | 63 (71) | 59 / 60 |
| 12_group_by_len | pass | pass (1 call) | pass | 152 (152) | 89 (89) | 102 / 68 |
| 13_spiral | pass | pass (1 call) | pass | 254 (254) | 206 (206) | 209 / 208 |
| 14_balanced | pass | pass (1 call) | pass | 137 (137) | 84 (84) | 107 / 75 |
| 15_calc | pass | pass (5 calls, 5/5 holes) | pass | 681 (681) | 635 (678) | 609 / 588 |
| 16_csv | pass | pass (1 call) | pass | 268 (268) | 219 (230) | 243 / 211 |
| 17_primes | pass | pass (1 call) | pass | 141 (141) | 115 (115) | 112 / 115 |
| 18_bst | pass | pass (4 calls, 4/4 holes) | pass | 215 (215) | 279 (279) | 194 / 175 |
| 19_wrap | pass | pass (1 call) | pass | 284 (284) | 136 (144) | 180 / 119 |
| 20_date | pass | pass (1 call) | pass | 384 (384) | 247 (247) | 266 / 209 |

### run2: claude-haiku-5-5

| task | Auk one-shot | Auk + hatch (model calls) | Python one-shot | Auk tokens code (raw) | Python tokens code (raw) | reference tokens Auk / Py |
|---|---|---|---|---|---|---|
| 01_word_freq | pass | pass (3 calls) | pass | 77 (77) | 56 (56) | 58 / 52 |
| 02_palindrome | pass | pass (1 call) | pass | 185 (185) | 41 (41) | 54 / 50 |
| 03_rle | pass | pass (2 calls, 2/2 holes) | pass | 305 (305) | 233 (245) | 281 / 230 |
| 04_parse_kv | pass | pass (1 call) | pass | 155 (155) | 143 (158) | 126 / 130 |
| 05_expr | pass | pass (2 calls, 2/2 holes) | pass | 179 (179) | 257 (258) | 166 / 209 |
| 06_bsearch | pass | pass (1 call) | pass | 101 (101) | 92 (92) | 95 / 88 |
| 07_merge_intervals | pass | pass (1 call) | pass | 247 (247) | 94 (94) | 120 / 89 |
| 08_roman | pass | pass (2 calls, 2/2 holes) | pass | 376 (376) | 307 (319) | 336 / 298 |
| 09_to_base | pass | pass (1 call) | pass | 148 (148) | 97 (108) | 127 / 92 |
| 10_bank | FAIL (no compile) | pass (1 call) | pass | 194 (194) | 136 (145) | 139 / 107 |
| 11_top_n | pass | pass (1 call) | pass | 217 (217) | 63 (71) | 59 / 60 |
| 12_group_by_len | pass | pass (1 call) | pass | 128 (128) | 76 (76) | 102 / 68 |
| 13_spiral | pass | pass (1 call) | pass | 241 (241) | 203 (203) | 209 / 208 |
| 14_balanced | pass | pass (1 call) | pass | 137 (137) | 79 (79) | 107 / 75 |
| 15_calc | pass | pass (5 calls, 5/5 holes) | pass | 767 (767) | 683 (726) | 609 / 588 |
| 16_csv | pass | pass (1 call) | pass | 265 (265) | 252 (290) | 243 / 211 |
| 17_primes | pass | pass (1 call) | pass | 145 (145) | 120 (120) | 112 / 115 |
| 18_bst | pass | pass (4 calls, 4/4 holes) | pass | 230 (230) | 292 (292) | 194 / 175 |
| 19_wrap | pass | pass (1 call) | pass | 206 (206) | 169 (178) | 180 / 119 |
| 20_date | pass | pass (1 call) | pass | 357 (357) | 225 (226) | 266 / 209 |

## Every Auk failure, analysed

There were 4 wrong Auk answers in 3 runs. Each one is a model not knowing or not trusting a spec
rule, and each was caught at compile time.

| # | run / task / condition | what the model wrote | diagnostic | cause | spec wording that would prevent it |
|---|---|---|---|---|---|
| 1 | haiku / 10_bank / one-shot (**the only one-shot failure**) | `Account { ..acct, balance: bal }` | E0020 `` `..base` must be the last thing in a struct literal `` (no fix-it) | Spec rule not stated. The spec only shows `Point { x: 3.0, ..p }`, and JS/TS habit puts the spread first. | Structs: "`..p` copies the remaining fields and **must come last**: `Point { x: 3.0, ..p }`." |
| 2 | haiku / 01_word_freq / hatch try 1 | `counts[k] = counts.get(k) ?? 0 + 1` | E0025 "expected a line break or `}` after the statement, found `0`" | The model guessed `??` is null-coalescing (C#/JS/Swift). In Auk `??` is a hole, and here it lexes as two postfix `?`. The diagnostic doesn't say what went wrong (see bug 3). | Errors and optionals: "A default for a missing value is `x else d`, not `x ?? d` (`??` is only a hole). `else` binds loosest: `(m.get(k) else 0) + 1`." |
| 3 | haiku / 01_word_freq / hatch try 2 | `let counts: {str: int} = {}` and then `counts[k] = ...` | "can't assign to `counts`: it isn't mutable" | The model didn't apply the `let`/`var` rule to maps. The spec does say `let` is immutable; this is a slip, not a gap. | Optional: "`let` maps and lists can't be changed either; use `var m: {K: V} = {}`." |
| 4 | sonnet / 02_palindrome / hatch try 1 | `for c in s.lower() { let n = int(c) ... }` | E0207 "can't loop over a `str`" (with a fix-it), **plus a spurious E0301** (bug 2) | Spec gap. It says `s[i]` is the i-th char and lists `chars`, but never says a `str` isn't iterable (it is in Python). | Control flow: "`for c in s.chars()` (a `str` itself is not iterable)." |

Also seen, outside the scored runs: in a pilot run of the harness (not kept), Opus wrote
`m.get(w) else 0 + 1` in its first hatch answer for 01_word_freq. It noticed `else` precedence itself
and corrected it in prose after the code block. Hatch's extractor takes the first fence, so the
uncorrected version was tested and failed the visible test. With a different `+ 1` the bug would
have been silent. The precedence line in the spec is right, but an example would help.

No failure was a genuinely hard task. The hard tasks (15_calc with 5 holes, 16_csv, 09_to_base with
the minimum int) passed in every run and condition.

## Why model-written Auk is longer: defensive code around unspecified library behaviour

I grepped the 60 one-shot Auk solutions (`runs/*/*/auk1/solution.auk`). The models avoid core
functions whose signature or semantics the spec only names:

| behaviour the spec leaves open | what the models wrote instead | examples |
|---|---|---|
| `sort_by` takes a key or a comparator? Is it stable? Are tuples `Ord`? | hand-written insertion sort helpers, or a struct with a custom `cmp` | run1 07_merge_intervals (242 tokens vs Python 94), run1 11_top_n (231 vs 63), haiku 07, haiku 11. Only sonnet used `sort_by(t => t.0)`. |
| char `lower`/`upper`/`is_alpha` exist? (the spec lists `upper lower` under Strings only, and `is_alpha` isn't in the spec at all) | `int(c)` code-point arithmetic: `if n >= 65 && n <= 90 { char(n + 32)! }` | 02_palindrome in all three runs (149-185 tokens vs Python 41-157), sonnet 03_rle and 20_date |
| return type of `s.find(sub)` (`int?`, char index) | its own `eq_index` loop over chars | run1 04_parse_kv |
| return type of `xs.pop()` (`T?`) | `stack.last()` plus re-slicing `stack[0..len-1]` | run1 14_balanced |
| sign of `/` and `%` for negatives (they truncate toward zero) | manual floor-division fix-ups (`if r > 0 { r -= base; q += 1 }`) | run1 09_to_base. Sonnet 09_to_base avoided negative `/`/`%` entirely with a digit-carry loop (258 tokens vs Python 123). |

My references use these functions directly and come out about 25% smaller than the model's Auk.
That gap, more than the language itself, is what makes model-written Auk larger than Python.

## Compiler bugs and diagnostic problems found

I fixed none of these; they are reported only.

**Bug 1. A parameter or local named like a core module is silently ignored in dot calls, and the
compiler's own fix-it then makes the code read the process environment.** The spec says both
"Local names shadow core ones" and "`m.` is always a path when `m` names a module". The compiler
applies the second rule silently. I hit this while writing task 05 with a parameter named `env`, and
renamed it to `vars` so the benchmark wouldn't be measuring this trap. Location: name resolution of
dot calls (`src/resolve.rs` / `src/check`, wherever `m.` is resolved as a module path).

```auk
// repro 1: confusing type error
fn f(env: {str: int}, name: str): int? = env.get(name)
// error[E0200]: expected `int?`, found `str?`   (it called core env.get)

// repro 2: following the compiler's fix-it gives silently wrong behaviour
fn lookup(env: {str: str}, k: str): str? = env.get(k)
// error[E0410]: `lookup` uses the effect `env` but doesn't declare it
//   = fix: insert ` uses env`
fn lookup2(env: {str: str}, k: str): str? uses env = env.get(k)
test "t" { assert lookup2({"HOME": "x"}, "HOME") == some("x") }
// FAIL: left: some("/Users/nate")  right: some("x")

// repro 3
fn total(time: [int]): int = time.sum()
// error[E0102]: module `core.time` has no function `sum`
```

Expected: either the local wins, which is what "local names shadow core ones" suggests, or a binding
that shadows a module name is an error at its declaration ("`env` names the core module `env`;
pick another name"). `auk hatch` would apply the E0410 fix-it loop happily. `env`, `time`, `fs`,
`net`, `proc` and `rand` are all common parameter names in model-written code.

**Bug 2. Cascading E0301 on an `{error}`-typed argument** (seen in sonnet 02_palindrome hatch try 1).

```auk
fn f(s: str): int {
  var t = 0
  for c in s { t += int(c) }
  t
}
// error[E0207]: can't loop over a `str`        <- correct
// error[E0301]: the call to `int` is ambiguous: 3 overloads take a `{error}` first   <- spurious
```

Overload resolution should stay silent when the first argument's type is already an error. The
spurious error was sent to the model as feedback.

**Bug 3 (diagnostic). `x ?? d` gives an unhelpful parse error.** `let n = m.get("a") ?? 0` reports
E0025 "expected a line break or `}` after the statement, found `0`". `??` followed by an expression
on the same line is almost always an attempt at null-coalescing. The parser could say "`??` is a hole;
for a default write `m.get("a") else 0`" and give a fix-it.

**Bug 4 (diagnostic, minor).** E0020 (`..base` must be last) has no fix-it, though the fix is
mechanical (move `..base` to the end).

Also noted while writing the tasks, and working as specified: `{}` inside a string literal is an
interpolation, so `"{[()]}"` must be written `"{{[()]}}"`; my own first draft of 14_balanced tripped
on it. There are no or-patterns (`')' | ']' => ...` is a lex error E0001). `x?.f()` on a `T!`
needs `(x?).f()`, and E0252's fix-it handles that well.

## Suggested spec changes (by expected impact)

1. **Give core library signatures, not just names.** This is the token win. One line each:
   `sort_by(key)` (stable; tuples, `str`, `int`, `char` are `Ord`, and tuples compare
   lexicographically), `pop(): T?`, `s.find(sub): int?` (char index), `get`, `first`/`last: T?`,
   `max`/`min: T?`, and `counts`. Also add `is_alpha is_space upper lower` for `char`. For example:
   "Collections: `xs.sort_by(x => key)` (stable, key must be `Ord`; tuples compare element by
   element) · `xs.pop(): T?` · `s.find(sub): int?` (char index)" and "Chars: `is_digit is_alpha
   is_space upper lower`".
2. **Arithmetic:** "`/` truncates toward zero and `%` takes the sign of the left side
   (`-7 / 2 == -3`, `-7 % 2 == -1`)."
3. **Defaults:** "A default for a missing value is `x else d` (`??` is only a hole); `else` binds
   loosest, so `(m.get(k) else 0) + 1`."
4. **Struct update:** "`..p` must come last."
5. **Strings:** "A `str` is not iterable: `for c in s.chars()`."
6. **Names:** either fix bug 1 or state it: "A local can't be used as a value named `fs`, `env`,
   `time`, `net`, `proc`, `rand`; `env.get` always means the module."

Items 1-2 address token cost and items 3-5 address the observed compile errors. Together they would
add about 120-150 tokens to the spec (about 5%).

## Honest caveats

- **One run per condition, n = 20.** The pass rates sit at or near the ceiling, so this benchmark
  can't tell Auk and Python apart on accuracy. "No measurable difference on easy-to-medium function
  tasks for Claude 5.5 models" is the defensible claim; "as accurate as Python" in general is not.
  One failure in 60 is noise.
- **Same model family.** All three models are Claude 5.5. Hatch, the one-shot prompts and the
  model being evaluated all come from the same family, and the tasks and tests were written by a
  Claude model (me). Another vendor's model, or a much smaller one, may behave differently, and its
  Python baseline might not be at 100%.
- **The tasks are mine, written to be checkable in both languages,** so they lean towards pure
  functions over strings, lists and maps. None of them exercise effects, async, modules/packages,
  JSON or the units/I-O features being added now. Multi-file programs, where Auk's whole-program
  token advantage was measured, aren't covered.
- **Prompt sensitivity.** The one-shot prompt says "Python 3.9" because the machine's python3 is
  3.9.6. Hatch builds its own prompt (spec + file + hole brief + JSON diagnostics), so the hatch
  and one-shot conditions differ in more than feedback. `claude -p` runs with its default system
  prompt, with tools disabled and settings sources off.
- **Visible vs hidden tests.** The hidden tests are a superset of the visible ones. A model that
  gets the visible tests right is told the visible cases explicitly, and hatch retries only on them.
- **Tokens** are counted with o200k (an OpenAI tokenizer), not Claude's. The ratios should be
  similar, but absolute numbers differ. "API output tokens" are Claude's own counts and include
  reasoning, and they are the real cost.
- The compiler and spec snapshot are from 2026-10-30, taken while other agents were editing
  `docs/spec.md` and the compiler. The spec-v2 re-run (top of this file) used a rebuilt compiler, so
  it differs from the first runs in the spec and in other agents' compiler fixes. Only the spec
  reaches the one-shot prompt, though, and no first-run failure depended on a compiler change.
